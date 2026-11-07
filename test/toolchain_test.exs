defmodule MLIR.ToolchainTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias MLIR.Toolchain

  test "resolves all pinned platforms without native code" do
    for {platform, revision} <- Toolchain.metadata()["llvm"]["default_revisions"] do
      [_, os, arch] = Regex.run(~r/^(macos|manylinux|windows)_(.+)$/, platform)

      output =
        capture_io(fn ->
          Toolchain.run(["--resolve-only", "--asset-os", os, "--asset-arch", arch])
        end)

      assert output =~ "LLVM_PREBUILT_ASSET_NAME=mlir_#{platform}_#{revision}.tar.gz"
      assert output =~ "https://github.com/llvm/eudsl/releases/download/llvm/"
    end
  end

  test "an explicit URL requires no release API lookup" do
    output =
      capture_io(fn ->
        Toolchain.run(["--resolve-only", "--asset-url", "https://example.com/custom.tar.gz"])
      end)

    assert output =~ "LLVM_PREBUILT_ASSET_NAME=custom.tar.gz"
    assert output =~ "LLVM_PREBUILT_URL=https://example.com/custom.tar.gz"
  end

  @tag :tmp_dir
  test "installs a wrapped archive and exports its actual llvm-config filename", %{tmp_dir: tmp} do
    asset =
      archive(tmp, [
        {"wrapped/bin/llvm-config.exe", "LLVM fixture"},
        {"wrapped/include/mlir.h", "header"}
      ])

    dest = Path.join(tmp, "install with spaces")
    exports = Path.join(tmp, "environment")

    output =
      capture_io(fn -> Toolchain.install_llvm!(asset, install_dir: dest, github_env: exports) end)

    assert File.read!(Path.join(dest, "include/mlir.h")) == "header"
    assert output =~ "LLVM_CONFIG_PATH=#{dest}/bin/llvm-config.exe"
    assert File.read!(exports) =~ "LLVM_CONFIG_PATH=#{dest}/bin/llvm-config.exe"
    refute File.exists?(Path.join(dest, "wrapped"))
  end

  @tag :tmp_dir
  test "checksum and malformed archive failures preserve the installed toolchain", %{tmp_dir: tmp} do
    dest = Path.join(tmp, "installed")
    File.mkdir_p!(Path.join(dest, "bin"))
    File.write!(Path.join(dest, "bin/llvm-config"), "original")
    asset = archive(tmp, [{"bin/llvm-config", "replacement"}])

    assert_raise Mix.Error, ~r/sha256 mismatch/, fn ->
      capture_io(fn ->
        Toolchain.install_llvm!(%{asset | sha256: String.duplicate("0", 64)}, install_dir: dest)
      end)
    end

    assert File.read!(Path.join(dest, "bin/llvm-config")) == "original"
    asset = archive(tmp, [{"wrong/tree", "missing config"}])

    assert_raise Mix.Error, ~r/expected one toolchain root/, fn ->
      capture_io(fn -> Toolchain.install_llvm!(asset, install_dir: dest) end)
    end

    assert File.read!(Path.join(dest, "bin/llvm-config")) == "original"
    assert Path.wildcard(Path.join(tmp, ".toolchain-*"), match_dot: true) == []
  end

  @tag :tmp_dir
  test "replaces an existing valid toolchain only after validation", %{tmp_dir: tmp} do
    dest = Path.join(tmp, "installed")
    File.mkdir_p!(Path.join(dest, "bin"))
    File.write!(Path.join(dest, "bin/llvm-config"), "old")
    File.write!(Path.join(dest, "obsolete"), "old")
    asset = archive(tmp, [{"bin/llvm-config", "new"}])
    capture_io(fn -> Toolchain.install_llvm!(asset, install_dir: dest) end)
    assert File.read!(Path.join(dest, "bin/llvm-config")) == "new"
    refute File.exists?(Path.join(dest, "obsolete"))
  end

  @tag :tmp_dir
  test "refuses unrelated directories and ambiguous archive roots", %{tmp_dir: tmp} do
    dest = Path.join(tmp, "unrelated")
    File.mkdir!(dest)
    File.write!(Path.join(dest, "keep"), "user file")
    asset = archive(tmp, [{"a/bin/llvm-config", "a"}, {"b/bin/llvm-config", "b"}])

    assert_raise Mix.Error, ~r/not an existing toolchain/, fn ->
      Toolchain.install_llvm!(asset, install_dir: dest)
    end

    assert File.read!(Path.join(dest, "keep")) == "user file"

    assert_raise Mix.Error, ~r/found 2/, fn ->
      capture_io(fn -> Toolchain.install_llvm!(asset, install_dir: Path.join(tmp, "new")) end)
    end
  end

  defp archive(tmp, entries) do
    path = Path.join(tmp, "fixture.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        Enum.map(entries, fn {name, data} -> {String.to_charlist(name), data} end),
        [:compressed]
      )

    %{
      name: "fixture.tar.gz",
      url: "file://#{path}",
      sha256: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    }
  end
end
