{
  lib,
  stdenv,
  rustPlatform,
  pkg-config,
  protobuf,
  cmake,
  perl,
  openssl,
  alsa-lib,
  ripgrep,
  bfs,
  ugrep,
  installShellFiles,
  versionCheckHook,
  grok-build-src,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "grok-build";
  version = "1.0.4";

  src = grok-build-src;

  cargoLock = {
    lockFile = grok-build-src + "/Cargo.lock";
    outputHashes = {
      "async-openai-0.33.1" = "sha256-pCq9Wo50T6SKlVbZk58v8NrhTi9iwZQ5cErm7uB9+eY=";
      "nucleo-0.5.0" = "sha256-ztSgjBI8vhKvrWmpT5K1UoHQRnbbrbEtSnvRkFmhSNc=";
    };
  };

  nativeBuildInputs = [
    cmake
    installShellFiles
    perl
    pkg-config
    protobuf
    rustPlatform.bindgenHook
  ];

  buildInputs =
    [
      openssl
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      alsa-lib
    ];

  env = {
    GROK_VERSION = finalAttrs.version;
    OPENSSL_NO_VENDOR = "1";
    PROTOC = lib.getExe protobuf;
    # Release builds download musl rg/fd from GitHub. Point them at
    # nixpkgs binaries so the sandbox never needs the network.
    GROK_TOOLS_BUNDLE_RG_PATH = lib.getExe ripgrep;
    GROK_SHELL_BUNDLE_RG_PATH = lib.getExe ripgrep;
    GROK_TOOLS_BUNDLE_BFS_PATH = lib.getExe bfs;
    GROK_TOOLS_BUNDLE_UGREP_PATH = lib.getExe ugrep;
  };

  cargoBuildFlags = ["--package" "xai-grok-pager-bin"];

  # Workspace tests are huge and many need a live environment.
  doCheck = false;

  postPatch = ''
    # Honor the nixpkgs toolchain instead of rustup's pin.
    rm -f rust-toolchain.toml

    # Flake inputs have no .git, so stamp the monorepo SOURCE_REV instead.
    short="$(head -c 7 SOURCE_REV)"
    substituteInPlace crates/codegen/xai-grok-pager-bin/build.rs \
      --replace-fail 'unwrap_or_else(|| "unknown".to_string())' \
      "unwrap_or_else(|| \"$short\".to_string())"
  '';

  postInstall =
    ''
      mv "$out/bin/xai-grok-pager" "$out/bin/grok"
      ln -s grok "$out/bin/agent"
    ''
    + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      installShellCompletion --cmd grok \
        --bash <("$out/bin/grok" completions bash) \
        --fish <("$out/bin/grok" completions fish) \
        --zsh <("$out/bin/grok" completions zsh)
    '';

  nativeInstallCheckInputs = [versionCheckHook];
  versionCheckProgramArg = "--version";
  doInstallCheck = true;

  meta = {
    description = "Command-line coding agent by xAI";
    homepage = "https://github.com/xai-org/grok-build";
    license = lib.licenses.asl20;
    mainProgram = "grok";
    platforms = lib.platforms.unix;
  };
})
