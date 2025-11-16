{
  delib,
  pkgs,
  lib,
  ...
}:
delib.module {
  name = "system.i18n";

  options.system.i18n = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {myconfig, ...}:
    lib.mkIf myconfig.host.isDesktop {
      i18n = {
        inputMethod = {
          enable = true;
          type = "ibus";
          ibus.engines = with pkgs.ibus-engines; [
            uniemoji
            typing-booster
          ];
        };
      };
    };
}
