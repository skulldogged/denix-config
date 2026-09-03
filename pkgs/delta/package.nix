{
  autoPatchelfHook,
  lib,
  libGL,
  libx11,
  makeWrapper,
  nodejs,
  requireFile,
  stdenv,
  vulkan-loader,
  wayland,
  xkeyboard_config,
}:
stdenv.mkDerivation (_finalAttrs: {
  pname = "delta";
  version = "0.4.0";

  src = requireFile {
    name = "delta-linux-x86_64.tar.gz";
    hash = "sha256-suIRakJGD7O6eyJmyceERZlFJ7tNQW7Z2gfiHcEryoI=";
    message = ''
      Delta is currently distributed through a private beta. Add the Linux
      x86_64 archive to the Nix store before building this package:

        nix-store --add-fixed sha256 /path/to/delta-linux-x86_64.tar.gz
    '';
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  runtimeDependencies = [
    libGL
    vulkan-loader
    wayland
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/delta "$out/bin/delta"
    cp -a lib "$out/lib"
    cp -a share "$out/share"

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram "$out/bin/delta" \
      --set XKB_CONFIG_ROOT ${xkeyboard_config}/share/X11/xkb \
      --set XLOCALEDIR ${libx11}/share/X11/locale \
      --suffix PATH : ${lib.makeBinPath [nodejs]}
  '';

  meta = {
    description = "Multiplayer environment for coding with agents and reviewing their work";
    homepage = "https://delta.dev";
    license = lib.licenses.unfree;
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    mainProgram = "delta";
    platforms = ["x86_64-linux"];
  };
})
