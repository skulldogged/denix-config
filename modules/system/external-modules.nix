{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "system.external-modules";

  nixos.always.imports = [
    inputs.sops-nix.nixosModules.sops
    inputs.impermanence.nixosModules.impermanence
    inputs.lanzaboote.nixosModules.lanzaboote
  ];
}
