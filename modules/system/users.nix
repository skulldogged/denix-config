{
  delib,
  pkgs,
  config,
  lib,
  ...
}:
delib.module {
  name = "system.users";

  options.system.users = with delib; {
    enable = boolOption false;
    extraGroups = listOption [];
    linger = boolOption false;
  };

  nixos.ifEnabled = {myconfig, ...}: {
    users = {
      mutableUsers = myconfig.host.isServer;

      users.${myconfig.constants.username} =
        {
          isNormalUser = true;
          linger = myconfig.system.users.linger;
          shell = pkgs.fish;

          extraGroups =
            [
              "disk"
              "gamemode"
              "input"
              "networkmanager"
              "video"
              "wheel"
            ]
            ++ myconfig.system.users.extraGroups;
        }
        // lib.optionalAttrs myconfig.host.isDesktop {
          hashedPasswordFile = config.sops.secrets.passwd.path;
        };
    };
  };
}
