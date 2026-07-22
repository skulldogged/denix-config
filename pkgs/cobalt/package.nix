{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  fetchPnpmDeps,
  ffmpeg-headless,
  node-gyp,
  nodejs,
  pnpmConfigHook,
  pnpm_10,
  python3,
  runtimeShell,
}: let
  pnpm = pnpm_10.override {nodejs-slim = nodejs;};
in
  buildNpmPackage rec {
    pname = "cobalt-api";
    version = "11.7.1-unstable-2026-07-07";

    src = fetchFromGitHub {
      owner = "zImPatrick";
      repo = "cobalt";
      rev = "56258ad6d1a71ca079a19340d17255e7576f7019";
      hash = "sha256-wUBGYPY2Mm9Ts094r+C9ITODIZWJMlBrHJu5KNaI/tQ=";
    };

    nativeBuildInputs = [
      node-gyp
      pnpm
      python3
    ];
    npmConfigHook = pnpmConfigHook;

    postPatch = ''
      cat > packages/version-info/index.js <<'EOF'
      export const getCommit = async () => "56258ad6d1a71ca079a19340d17255e7576f7019";
      export const getBranch = async () => "meowing.de";
      export const getRemote = async () => "zImPatrick/cobalt";
      export const getVersion = async () => "11.7.1";
      EOF

      substituteInPlace api/src/stream/ffmpeg.js \
        --replace-fail 'import ffmpeg from "ffmpeg-static";' 'const ffmpeg = "${lib.getExe ffmpeg-headless}";'

      substituteInPlace web/src/lib/api/api-url.ts \
        --replace-fail "return new URL(customInstanceURL).origin;" "return new URL(customInstanceURL).href.replace(/\/$/, \"\");" \
        --replace-fail "return new URL(env.DEFAULT_API!).origin;" "return new URL(env.DEFAULT_API!).href.replace(/\/$/, \"\");"
    '';

    npmDeps = pnpmDeps;
    pnpmDeps = fetchPnpmDeps {
      inherit pname version src pnpm;
      fetcherVersion = 3;
      hash = "sha256-SjdNFfvP973rjNyQ9Bf6wkxxsFWvnw3ezPuLm/Z6OrY=";
    };

    buildPhase = ''
      runHook preBuild
      (
        cd node_modules/.pnpm/isolated-vm@6.0.2/node_modules/isolated-vm
        node-gyp rebuild --release -j "$NIX_BUILD_CORES"
      )
      (
        export WEB_DEFAULT_API="https://cobalt.skulldogged.dev/api"
        export WEB_HOST="cobalt.skulldogged.dev"
        cd web
        pnpm build
      )
      runHook postBuild
    '';

    installPhase = ''
          runHook preInstall
          mkdir -p "$out/bin"
          mkdir -p "$out/lib/cobalt"
          mkdir -p "$out/share"
          cp -a api packages web package.json pnpm-lock.yaml pnpm-workspace.yaml node_modules "$out/lib/cobalt/"
          cp -a web/build "$out/share/cobalt-web"
          cat > "$out/bin/cobalt-api" <<EOF
      #!${runtimeShell}
      cd "$out/lib/cobalt/api"
      exec ${lib.getExe nodejs} src/cobalt.js
      EOF
          chmod +x "$out/bin/cobalt-api"
          runHook postInstall
    '';

    meta = {
      homepage = "https://github.com/zImPatrick/cobalt";
      description = "Media downloader API";
      license = lib.licenses.agpl3Only;
      mainProgram = "cobalt-api";
    };
  }
