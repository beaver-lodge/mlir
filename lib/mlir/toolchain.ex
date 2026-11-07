defmodule MLIR.Toolchain do
  @moduledoc "Download and install LLVM/MLIR distributions without a native build."
  @metadata_path Path.expand("../../priv/toolchain.json", __DIR__)
  @external_resource @metadata_path
  def metadata,
    do: :mlir |> Application.app_dir("priv/toolchain.json") |> File.read!() |> JSON.decode!()

  @switches [
    install_dir: :string,
    repo: :string,
    tag: :string,
    asset_revision: :string,
    asset_name: :string,
    asset_url: :string,
    asset_os: :string,
    asset_arch: :string,
    sha256: :string,
    github_token: :string,
    github_env: :string,
    resolve_only: :boolean,
    print_metadata: :boolean
  ]

  def switches, do: @switches

  def run(args, defaults \\ []) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    if opts[:print_metadata] do
      if positional != [], do: Mix.raise("--print-metadata does not accept positional arguments")
      IO.puts(JSON.encode!(metadata()))
    else
      opts = opts |> reject_empty() |> Keyword.merge(defaults) |> merge_env()

      install_dir = opts[:install_dir] || List.first(positional) || default_install_dir()
      {os_name, arch} = platform(opts)
      opts = put_default_asset_revision(opts, os_name, arch)
      {asset_name, asset_url, sha256} = resolve_asset(opts, os_name, arch)

      if opts[:resolve_only] do
        if opts[:asset_revision],
          do: IO.puts("LLVM_EUDSL_ASSET_REVISION=#{opts[:asset_revision]}")

        IO.puts("LLVM_PREBUILT_ASSET_NAME=#{asset_name}")
        IO.puts("LLVM_PREBUILT_URL=#{asset_url}")
        if sha256, do: IO.puts("LLVM_EUDSL_SHA256=#{sha256}")
      else
        install!(install_dir, asset_name, asset_url, sha256, opts[:github_env])
      end
    end
  end

  defp merge_env(opts) do
    opts
    |> put_default(:repo, (opts[:metadata] || metadata()["llvm"])["repo"], "LLVM_EUDSL_REPO")
    |> put_default(:tag, (opts[:metadata] || metadata()["llvm"])["tag"], "LLVM_EUDSL_TAG")
    |> put_env(:asset_revision, "LLVM_EUDSL_ASSET_REVISION")
    |> put_env(:install_dir, "LLVM_PREBUILT_DIR")
    |> put_env(:asset_name, "LLVM_EUDSL_ASSET_NAME")
    |> put_env(:asset_url, "LLVM_EUDSL_ASSET_URL")
    |> put_env(:asset_os, "LLVM_EUDSL_ASSET_OS")
    |> put_env(:asset_arch, "LLVM_EUDSL_ASSET_ARCH")
    |> put_env(:sha256, "LLVM_EUDSL_SHA256")
    |> put_env(:github_env, "GITHUB_ENV")
    |> put_env(:github_token, "GITHUB_TOKEN")
    |> put_env(:github_token, "GH_TOKEN")
    |> maybe_resolve_only()
  end

  defp put_default_asset_revision(opts, os_name, arch) do
    if Enum.any?(
         [:asset_revision, :asset_name, :asset_url],
         &Keyword.has_key?(opts, &1)
       ) do
      opts
    else
      Keyword.put(
        opts,
        :asset_revision,
        Map.fetch!(
          (opts[:metadata] || metadata()["llvm"])["default_revisions"],
          "#{os_name}_#{arch}"
        )
      )
    end
  end

  defp reject_empty(opts) do
    Enum.reject(opts, fn {_key, value} -> value == "" end)
  end

  defp put_default(opts, key, default, env) do
    if Keyword.has_key?(opts, key) do
      opts
    else
      case System.get_env(env) do
        value when value in [nil, ""] -> Keyword.put(opts, key, default)
        value -> Keyword.put(opts, key, value)
      end
    end
  end

  defp put_env(opts, key, env) do
    if Keyword.has_key?(opts, key) do
      opts
    else
      case System.get_env(env) do
        value when value in [nil, ""] -> opts
        value -> Keyword.put(opts, key, value)
      end
    end
  end

  defp maybe_resolve_only(opts) do
    if System.get_env("LLVM_EUDSL_RESOLVE_ONLY") == "1" do
      Keyword.put_new(opts, :resolve_only, true)
    else
      opts
    end
  end

  defp default_install_dir do
    base = System.get_env("RUNNER_TEMP") || System.get_env("TMPDIR") || "/tmp"
    Path.join(base, "llvm-prebuilt")
  end

  def platform(opts \\ []) do
    os_name = opts[:asset_os] || detect_os()
    arch = opts[:asset_arch] || detect_arch(os_name)
    {os_name, arch}
  end

  defp detect_os do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, _} -> "manylinux"
      {:win32, _} -> "windows"
      other -> Mix.raise("unsupported operating system: #{inspect(other)}")
    end
  end

  defp detect_arch("windows"), do: "amd64"

  defp detect_arch(os_name) do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    arm? = String.starts_with?(arch, "aarch64") or String.starts_with?(arch, "arm64")

    case {os_name, arm?} do
      {"macos", true} -> "arm64"
      {"macos", false} -> "x86_64"
      {_, true} -> "aarch64"
      {_, false} -> "x86_64"
    end
  end

  defp resolve_asset(opts, os_name, arch) do
    cond do
      is_binary(opts[:asset_url]) ->
        {opts[:asset_name] || Path.basename(opts[:asset_url]), opts[:asset_url], opts[:sha256]}

      true ->
        name =
          opts[:asset_name] ||
            case opts[:asset_revision] do
              "latest" -> resolve_latest_asset!(opts, os_name, arch)
              revision -> "mlir_#{os_name}_#{arch}_#{revision}.tar.gz"
            end

        url = "https://github.com/#{opts[:repo]}/releases/download/#{opts[:tag]}/#{name}"
        {name, url, opts[:sha256]}
    end
  end

  defp resolve_latest_asset!(opts, os_name, arch) do
    ensure_http!()
    prefix = "mlir_#{os_name}_#{arch}_"
    release = github_get!(release_url(opts), opts[:github_token])
    assets = fetch_all_assets!(release["id"], opts)

    matches =
      Enum.filter(assets, fn asset ->
        String.starts_with?(asset["name"], prefix) and
          String.ends_with?(asset["name"], ".tar.gz")
      end)

    case matches
         |> Enum.sort_by(fn asset -> {asset["updated_at"] || "", asset["name"]} end)
         |> List.last() do
      nil ->
        Mix.raise("no llvm/eudsl asset found for #{os_name}/#{arch} under tag #{opts[:tag]}")

      asset ->
        asset["name"]
    end
  end

  defp release_url(opts) do
    "https://api.github.com/repos/#{opts[:repo]}/releases/tags/#{opts[:tag]}"
  end

  defp fetch_all_assets!(release_id, opts) do
    Enum.reduce_while(1..10, [], fn page, acc ->
      url =
        "https://api.github.com/repos/#{opts[:repo]}/releases/#{release_id}/assets?per_page=100&page=#{page}"

      case github_get!(url, opts[:github_token]) do
        [] -> {:halt, acc}
        assets -> {:cont, acc ++ assets}
      end
    end)
  end

  def github_get!(url, token \\ nil) do
    ensure_http!()

    headers =
      [
        {~c"Accept", ~c"application/vnd.github+json"},
        {~c"User-Agent", ~c"mlir-toolchain"},
        {~c"X-GitHub-Api-Version", ~c"2022-11-28"}
      ]

    headers =
      case token do
        nil -> headers
        token -> [{~c"Authorization", String.to_charlist("Bearer #{token}")} | headers]
      end

    http_opts = [timeout: 30_000, connect_timeout: 15_000]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        JSON.decode!(body)

      {:ok, {{_, status, _}, _, body}} ->
        Mix.raise("GitHub API #{status} for #{url}: #{inspect(body)}")

      {:error, reason} ->
        Mix.raise("GitHub API request failed for #{url}: #{inspect(reason)}")
    end
  end

  defp ensure_http! do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
  end

  def install_llvm!(asset, opts) do
    install!(
      opts[:install_dir] || default_install_dir(),
      asset.name,
      asset.url,
      asset[:sha256],
      opts[:github_env]
    )
  end

  defp install!(install_dir, name, url, sha256, github_env) do
    markers = ["bin/llvm-config", "bin/llvm-config.exe"]
    dir = install_archive!(install_dir, %{name: name, url: url, sha256: sha256}, markers)

    config =
      Enum.find_value(markers, fn marker ->
        path = Path.join(dir, marker)
        if File.regular?(path), do: path
      end)

    File.chmod!(config, 0o755)
    IO.puts("Installed #{name} into #{dir}")
    IO.puts("LLVM_CONFIG_PATH=#{config}")
    write_github_env!(dir, config, name, url, github_env)
    dir
  end

  @doc "Install a native archive after checksum verification, preserving the old tree on failure."
  def install_archive!(install_dir, asset, marker) do
    markers = List.wrap(marker)
    dir = Path.expand(install_dir)

    if dir in [Path.expand("/"), System.user_home!(), File.cwd!()] or install_dir == "",
      do: Mix.raise("refusing to replace protected directory #{dir}")

    if File.exists?(dir) and File.ls!(dir) != [] and
         not Enum.any?(markers, &File.regular?(Path.join(dir, &1))),
       do: Mix.raise("destination is not an existing toolchain: #{dir}")

    parent = Path.dirname(dir)
    File.mkdir_p!(parent)
    tmp = Path.join(parent, ".toolchain-#{System.pid()}-#{System.unique_integer([:positive])}")
    archive = Path.join(tmp, "asset.tar.gz")
    extracted = Path.join(tmp, "extract")
    previous = Path.join(tmp, "previous")

    try do
      File.mkdir!(tmp)
      download!(asset.url, archive)
      verify_sha256!(archive, asset[:sha256])
      extract!(archive, extracted)
      roots = find_roots(extracted, markers)

      root =
        case roots do
          [root] -> root
          _ -> Mix.raise("expected one toolchain root in #{asset.name}, found #{length(roots)}")
        end

      if File.exists?(dir), do: File.rename!(dir, previous)

      try do
        File.rename!(root, dir)
      rescue
        error ->
          if File.exists?(previous), do: File.rename!(previous, dir)
          reraise error, __STACKTRACE__
      end

      dir
    after
      File.rm_rf!(tmp)
    end
  end

  defp find_roots(dir, markers) do
    if Enum.any?(markers, &File.regular?(Path.join(dir, &1))) do
      [dir]
    else
      for entry <- File.ls!(dir),
          child = Path.join(dir, entry),
          match?({:ok, %File.Stat{type: :directory}}, File.lstat(child)),
          root <- find_roots(child, markers),
          do: root
    end
  end

  defp download!(url, path) do
    IO.puts("Downloading #{url}")

    cond do
      System.find_executable("curl") ->
        run_download(
          [
            "curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--retry",
            "3",
            "--output",
            path,
            "--url",
            url
          ],
          url
        )

      System.find_executable("wget") ->
        run_download(["wget", "--quiet", "--output-document", path, url], url)

      true ->
        Mix.raise("curl or wget is required to download #{url}")
    end
  end

  defp run_download(command, url) do
    {output, status} = System.cmd(hd(command), tl(command), stderr_to_stdout: true)

    unless status == 0 do
      Mix.raise("download failed with status #{status} for #{url}:\n#{output}")
    end

    :ok
  end

  defp verify_sha256!(_path, nil), do: :ok

  defp verify_sha256!(path, expected) do
    digest =
      path
      |> File.stream!(1_048_576, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, ctx ->
        :crypto.hash_update(ctx, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    unless digest == String.downcase(expected) do
      Mix.raise("sha256 mismatch for #{path}: expected #{expected}, got #{digest}")
    end

    :ok
  end

  defp extract!(archive, extract_dir) do
    File.mkdir_p!(extract_dir)

    if match?({:win32, _}, :os.type()) do
      # Windows runners do not guarantee a usable system tar for these
      # archives, so go through erl_tar for the Windows prebuilt. The Unix
      # archives cannot use erl_tar: they store negative base-256 mtime fields
      # (reproducible builds) that erl_tar rejects with :integer_overflow, and
      # they rely on symlinks that the system tar handles faithfully.
      case :erl_tar.extract(String.to_charlist(archive), [
             :compressed,
             {:cwd, String.to_charlist(extract_dir)}
           ]) do
        :ok -> :ok
        {:error, reason} -> Mix.raise("failed to extract #{archive}: #{inspect(reason)}")
      end
    else
      {output, status} =
        System.cmd("tar", ["-xzf", archive, "-C", extract_dir], stderr_to_stdout: true)

      unless status == 0 do
        Mix.raise("failed to extract #{archive}:\n#{output}")
      end

      :ok
    end
  end

  defp write_github_env!(install_dir, config, asset_name, asset_url, github_env) do
    case github_env do
      nil ->
        :ok

      path ->
        content = """
        LLVM_CONFIG_PATH=#{config}
        LLVM_PREBUILT_DIR=#{install_dir}
        LLVM_PREBUILT_ASSET_NAME=#{asset_name}
        LLVM_PREBUILT_URL=#{asset_url}
        """

        File.write!(path, content, [:append])
    end
  end
end
