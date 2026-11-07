# MLIR toolchain

Install prebuilt LLVM/MLIR distributions for Elixir projects.
The Hex package is `mlir`; Elixir modules use `MLIR.Toolchain`.
This package distributes the installer and pinned metadata. Native archives
remain in upstream releases and are downloaded when the install task runs.

```elixir
{:mlir, "~> 0.1.0", runtime: false}
```

```sh
mix mlir.install --resolve-only
mix mlir.install --install-dir /path/to/llvm
mix mlir.install --asset-revision latest --resolve-only
mix mlir.install --asset-url https://example.com/llvm.tar.gz --sha256 HASH --install-dir /path/to/llvm
```

`LLVM_CONFIG_PATH` is printed after installation. `--github-env PATH` appends
the actual config path and asset identity to an environment file. Existing
`LLVM_EUDSL_*`, `LLVM_PREBUILT_DIR`, `GH_TOKEN`/`GITHUB_TOKEN` and `GITHUB_ENV`
inputs remain supported. Explicit options take precedence.

Defaults are in `priv/toolchain.json`; the supported pinned platforms are
Linux x86_64/aarch64, macOS arm64 and Windows amd64. An explicit URL can select
another distribution. `--sha256` verifies the archive before replacement;
invalid archives preserve the existing toolchain. Installs refuse unrelated
nonempty directories. The package does not provide MLIR bindings or a NIF.

Triton-specific LLVM selection and native core builds live in the separate
`openai_triton` package. Triton must use its paired LLVM distribution.

Requires Elixir >= 1.18, curl or wget, and tar on Unix. Run `mix test` and
`mix hex.build` from this checkout. This extraction is prepared for its first
Hex release; a successful local package build does not publish or reserve a name.
Installer code is distributed under the MIT license. Downloaded LLVM
distributions retain their upstream licenses.
