{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "system.external-modules";

  nixos.always.imports = [
    inputs.cua.nixosModules.cua-driver
    inputs.sops-nix.nixosModules.sops
    inputs.impermanence.nixosModules.impermanence
    inputs.lanzaboote.nixosModules.lanzaboote
    (
      {pkgs, ...}: let
        # sops-nix still requests this builder after its removal from nixpkgs.
        sopsCompatPkgs = pkgs.extend (_: prev: {
          buildGo125Module = prev.buildGoModule;
        });
      in {
        sops.package = (import inputs.sops-nix {pkgs = sopsCompatPkgs;}).sops-install-secrets;
      }
    )
  ];
}
