defmodule Mix.Tasks.Mlir.Install do
  use Mix.Task
  @shortdoc "Install an LLVM/MLIR toolchain"
  @moduledoc "Run with --resolve-only to inspect the asset, or --install-dir PATH to install it."
  def run(args), do: MLIR.Toolchain.run(args)
end
