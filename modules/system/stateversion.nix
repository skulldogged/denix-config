{delib, ...}:
delib.module {
  name = "system.stateversion";

  options.system.stateversion = with delib; {
    version = strOption "24.05";
  };

  nixos.always = {myconfig, ...}: {
    system.stateVersion = myconfig.system.stateversion.version;
  };

  home.always = {myconfig, ...}: {
    home.stateVersion = myconfig.system.stateversion.version;
  };
}
