{
  lib,
  llvmPackages_latest,
  meson,
  ninja,
  pkg-config,
  wayland-scanner,
  libgbm,
  libglvnd,
  lz4,
  stb,
  wayland,
  wayland-protocols,
  wlr-protocols,
}:
llvmPackages_latest.stdenv.mkDerivation {
  pname = "ranni-wallpaper";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    wayland-scanner
    wayland-protocols
    wlr-protocols
  ];

  buildInputs = [
    libgbm
    libglvnd
    lz4
    stb
    wayland
  ];

  mesonBuildType = "release";
  mesonFlags = ["-Db_lto=true"];

  meta = {
    description = "Intel-rendered scene-specific Ranni wallpaper for Wayland";
    mainProgram = "ranni-wallpaper";
    platforms = lib.platforms.linux;
  };
}
