{
  stdenv,
  nodejs,
  pnpm,
  inputs,
  ...
}:
stdenv.mkDerivation rec {
  pname = "cobalt-web";
  version = "latest";

  src = inputs.cobalt;

  nativeBuildInputs = [
    nodejs
    pnpm.configHook
  ];

  pnpmDeps = pnpm.fetchDeps {
    inherit pname version src;
    fetcherVersion = 2;
    hash = "sha256-5RNa4M7Mbk5zwbi/5StHGz1wmOec1p4O9UteftHzLjQ=";
  };

  env = {
    WEB_DEFAULT_API = "https://cobalt.skulldogged.dev";
    WEB_HOST = "cobalt.skulldogged.dev";
  };

  postPatch = ''
    cat > packages/version-info/index.js <<EOF
    export const getCommit = async () => "nix-build";
    export const getBranch = async () => "main";
    export const getRemote = async () => "imputnet/cobalt";
    export const getVersion = async () => "latest";
    EOF

    # Remove CSP config to fix blank page issue
    sed -i '/csp: {/,/},/d' web/svelte.config.js
  '';

  buildPhase = ''
    runHook preBuild

    pnpm --filter @imput/cobalt-web build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r web/build/* $out/

    runHook postInstall
  '';
}
