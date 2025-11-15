{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "system.i18n";

  options.system.i18n = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
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
