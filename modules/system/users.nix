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
  };

  nixos.ifEnabled = {myconfig, ...}: {
    users = {
      mutableUsers = myconfig.host.isServer;

      users.${myconfig.constants.username} =
        {
          isNormalUser = true;
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
          hashedPasswordFile = config.age.secrets.passwd.path;
        };
    };
  };
}
