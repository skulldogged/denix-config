{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "nixpkgs";

  nixos.always.nixpkgs = {
    config.allowUnfree = true;

    overlays = [
      (_final: prev: {
        local = {
          cobalt = prev.callPackage ../../pkgs/cobalt/package.nix {};
          jellyfin = prev.callPackage ../../pkgs/jellyfin/package.nix {
            inherit inputs;
            pkgs = prev;
          };
          ranni-wallpaper = prev.callPackage ../../pkgs/ranni-wallpaper/package.nix {};
          slskd = prev.callPackage ../../pkgs/slskd/package.nix {};
        };
      })
    ];
  };

  darwin.always.nixpkgs.config.allowUnfree = true;
}
