defmodule MLIR.MixProject do
  use Mix.Project

  def project do
    [
      app: :mlir,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "LLVM/MLIR toolchain installation for Elixir",
      package: [
        links: %{
          "Upstream" => "https://mlir.llvm.org/"
        },
        licenses: ["MIT"],
        files: ["lib", "priv", "mix.exs", ".formatter.exs", "README.md", "LICENSE"]
      ],
      deps: []
    ]
  end

  def application, do: [extra_applications: [:crypto, :inets, :ssl]]
end
