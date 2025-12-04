{
  pkgs,
  inputs,
}: let
  # Stage 1: Create a patched source derivation that includes our .npmrc file.
  # Using runCommand is a clean way to handle adding a file to a plain directory source.
  patched-cobalt-src = pkgs.stdenv.mkDerivation {
    pname = "cobalt-src-with-npmrc";
    version = inputs.cobalt.rev;
    src = inputs.cobalt;

    nativeBuildInputs = [pkgs.yq-go];

    installPhase = ''
      mkdir -p $out
      cp -r $src/. $out
      chmod -R u+w $out
      yq -i '.settings.injectWorkspacePackages = true' $out/pnpm-lock.yaml
      echo "inject-workspace-packages=true" > $out/.npmrc
    '';
  };

  # Stage 2: Use this patched source to fetch dependencies.
  pnpmDeps = pkgs.pnpm.fetchDeps {
    pname = "cobalt-api";
    version = inputs.cobalt.rev;
    src = patched-cobalt-src;
    fetcherVersion = 2;
    hash = "sha256-5RNa4M7Mbk5zwbi/5StHGz1wmOec1p4O9UteftHzLjQ=";
  };
in
  # Stage 3: Main derivation, using the patched source and pre-fetched deps.
  pkgs.stdenv.mkDerivation {
    pname = "cobalt-api";
    version = inputs.cobalt.rev;

    src = patched-cobalt-src;

    nativeBuildInputs = [
      pkgs.nodejs_20
      pkgs.pnpm
      pkgs.pnpm.configHook
    ];

    inherit pnpmDeps;

    preConfigure = ''
      export HOME=$(mktemp -d)
    '';

    postPatch = ''
      cat > packages/version-info/index.js <<EOF
      export const getCommit = async () => "${inputs.cobalt.rev}";
      export const getBranch = async () => "main";
      export const getRemote = async () => "imputnet/cobalt";
      export const getVersion = async () => "latest";
      EOF
    '';

    buildPhase = ''
      runHook preBuild
      export CI=true
      pnpm --filter @imput/cobalt-api deploy --prod ../cobalt-api-deploy
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R ../cobalt-api-deploy/* $out/
      mkdir -p $out/bin
      cat <<EOF > $out/bin/cobalt-api
      #!${pkgs.runtimeShell}
      export PATH="${pkgs.lib.makeBinPath [pkgs.ffmpeg]}:\$PATH"
      cd $out
      exec ${pkgs.nodejs_20}/bin/node src/cobalt.js
      EOF
      chmod +x $out/bin/cobalt-api

      # Fix ffmpeg-static usage by symlinking system ffmpeg
      mkdir -p $out/node_modules/ffmpeg-static
      ln -sf ${pkgs.lib.getExe pkgs.ffmpeg} $out/node_modules/ffmpeg-static/ffmpeg

      runHook postInstall
    '';
  }
