{
  delib,
  lib,
  ...
}:
delib.module {
  name = "system.networking";

  options.system.networking = with delib; {
    enable = boolOption false;
    hostName = strOption "navis";
  };

  nixos.ifEnabled = {myconfig, ...}: {
    networking = {
      firewall.enable = true;
      hostName = myconfig.system.networking.hostName;
      useDHCP = lib.mkForce true;

      networkmanager = {
        enable = true;
        insertNameservers = [
          "1.1.1.1"
          "1.0.0.1"
        ];
      };
    };
  };
}
