{
  delib,
  pkgs,
  config,
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
      mutableUsers = false;

      users.${myconfig.constants.username} = {
        hashedPasswordFile = config.age.secrets.passwd.path;
        isNormalUser = true;
        shell = pkgs.fish;

        extraGroups =
          [
            "disk"
            "docker"
            "gamemode"
            "input"
            "libvirtd"
            "networkmanager"
            "video"
            "wheel"
          ]
          ++ myconfig.system.users.extraGroups;
      };
    };

    virtualisation = {
      spiceUSBRedirection.enable = true;
      docker.enable = true;
    };
  };
}
