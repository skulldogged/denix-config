{
  coreutils,
  ffmpeg-headless,
  lib,
  python313,
  stdenvNoCC,
  uv,
  writeShellApplication,
}: let
  version = "0.1.0";
  runtime = writeShellApplication {
    name = "lidarr-gamdl-bridge";
    runtimeInputs = [
      coreutils
      ffmpeg-headless
    ];
    text = ''
      exec ${lib.getExe uv} run \
        --no-project \
        --python ${lib.getExe python313} \
        --with gamdl==3.8.5 \
        python ${./bridge.py} "$@"
    '';
  };
in
  stdenvNoCC.mkDerivation {
    pname = "lidarr-gamdl-bridge";
    inherit version;
    src = ./.;

    nativeBuildInputs = [python313];
    dontBuild = true;
    doCheck = true;

    checkPhase = ''
      runHook preCheck
      ${lib.getExe python313} -m unittest discover -s tests -v
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/lidarr-gamdl-bridge"
      cp bridge.py "$out/share/lidarr-gamdl-bridge/bridge.py"
      cp ${runtime}/bin/lidarr-gamdl-bridge "$out/bin/lidarr-gamdl-bridge"
      runHook postInstall
    '';

    meta = {
      description = "Newznab and SABnzbd compatibility bridge between Lidarr and gamdl";
      license = lib.licenses.mit;
      mainProgram = "lidarr-gamdl-bridge";
      platforms = lib.platforms.linux;
    };
  }
