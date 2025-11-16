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

  nixos.ifEnabled = {myconfig, ...}: {
    programs = {
      fish.enable = true;
      gamemode.enable = myconfig.host.isDesktop;

      appimage = {
        enable = true;
        binfmt = true;
      };

      hyprland = pkgs.lib.mkIf myconfig.host.isDesktop {
        enable = true;
        package = inputs.hyprland.packages.${pkgs.system}.hyprland;
        portalPackage = inputs.hyprland.packages.${pkgs.system}.xdg-desktop-portal-hyprland;
      };

      nh = {
        enable = true;
        flake = "/home/marshall/nix-config";
      };

      nix-ld = pkgs.lib.mkIf myconfig.host.isDesktop {
        enable = true;
        libraries = with pkgs; [
          icu
          gmp
          glibc
          openssl
          stdenv.cc.cc
        ];
      };

      obs-studio = pkgs.lib.mkIf myconfig.host.isDesktop {
        enable = true;
        enableVirtualCamera = true;
      };

      steam = pkgs.lib.mkIf myconfig.host.isDesktop {
        enable = true;
        extraCompatPackages = [pkgs.proton-ge-custom];
      };

      gnupg.agent = {
        enable = true;
        pinentryPackage =
          if myconfig.host.isDesktop
          then pkgs.pinentry-gnome3
          else pkgs.pinentry-curses;
      };
      ssh.startAgent = myconfig.host.isServer;
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
