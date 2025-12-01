{
  lib,
  stdenvNoCC,
  bun,
  writableTmpDirAsHomeHook,
  version,
  src,
}:
stdenvNoCC.mkDerivation {
  inherit version src;
  pname = "equibop-modules";

  impureEnvVars =
    lib.fetchers.proxyImpureEnvVars
    ++ [
      "GIT_PROXY_COMMAND"
      "SOCKS_SERVER"
    ];

  nativeBuildInputs = [
    bun
    writableTmpDirAsHomeHook
  ];

  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    export BUN_INSTALL_CACHE_DIR=$(mktemp -d)

    bun install \
        --filter=equibop \
        --force \
        --frozen-lockfile \
        --ignore-scripts \
        --linker=hoisted \
        --no-progress

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    cp -R ./node_modules $out

    runHook postInstall
  '';

  outputHash = "sha256-hUa+IVHhQgHrvK3qhm4urevPyyt0XEtIrmp14tdb8+4=";
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
}
