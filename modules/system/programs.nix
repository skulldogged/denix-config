{
  delib,
  pkgs,
  inputs,
  ...
}:
delib.module {
  name = "system.programs";

  options.system.programs = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    programs = {
      fish.enable = true;
      gamemode.enable = true;

      appimage = {
        enable = true;
        binfmt = true;
      };

      hyprland = {
        enable = true;
        package = inputs.hyprland.packages.${pkgs.system}.hyprland;
        portalPackage = inputs.hyprland.packages.${pkgs.system}.xdg-desktop-portal-hyprland;
      };

      nh = {
        enable = true;
        flake = "/home/marshall/denix-config";
      };

      nix-ld = {
        enable = true;
        libraries = with pkgs; [
          icu
          gmp
          glibc
          openssl
          stdenv.cc.cc
        ];
      };

      obs-studio = {
        enable = true;
        enableVirtualCamera = true;
      };

      steam = {
        enable = true;
        extraCompatPackages = [pkgs.proton-ge-custom];
      };
    };
  };

  darwin.ifEnabled = {
    programs = {
      fish.enable = true;
      gnupg.agent = {
        enable = true;
        enableSSHSupport = true;
      };
    };
  };
}
