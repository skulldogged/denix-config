{
  delib,
  inputs,
  ...
}: let
  overlay = _: prev: {
    local = {
      cobalt = prev.callPackage ../../pkgs/cobalt/package.nix {};
      delta = prev.callPackage ../../pkgs/delta/package.nix {};
      jellyfin = prev.callPackage ../../pkgs/jellyfin/package.nix {
        inherit inputs;
        pkgs = prev;
      };
      lidarr = prev.callPackage ../../pkgs/lidarr/package.nix {};
      lidarr-gamdl-bridge = prev.callPackage ../../pkgs/lidarr-gamdl-bridge/package.nix {};
      lidarr-plugin-slskd = prev.callPackage ../../pkgs/lidarr-plugin-slskd/package.nix {};
      ranni-wallpaper = prev.callPackage ../../pkgs/ranni-wallpaper/package.nix {};
      slskd = prev.callPackage ../../pkgs/slskd/package.nix {};
      visor-bootmanager = prev.callPackage ../../pkgs/visor-bootmanager/package.nix {};
    };

    grok-build = prev.callPackage ../../pkgs/grok-build/package.nix {inherit (inputs) grok-build-src;};
  };
in
  delib.module {
    name = "nixpkgs";

    nixos.always.nixpkgs = {
      config.allowUnfree = true;
      overlays = [overlay];
    };

    darwin.always.nixpkgs = {
      config.allowUnfree = true;
      overlays = [overlay];
    };
  }
