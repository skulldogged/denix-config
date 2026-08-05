{
  delib,
  pkgs,
  lib,
  ...
}:
delib.module {
  name = "programs.mpv";

  options.programs.mpv = with delib; {
    enable = boolOption false;

    hardwareDecodeDevice =
      description
      (strOption "")
      "VA-API device used for copy-back hardware video decoding. Empty disables hardware decoding.";
  };

  home.ifEnabled = {myconfig, ...}: let
    cfg = myconfig.programs.mpv;
    hardwareDecodeEnabled = cfg.hardwareDecodeDevice != "";
  in {
    programs.mpv = {
      enable = true;
      extraMakeWrapperArgs = lib.optionals hardwareDecodeEnabled [
        "--set"
        "LIBVA_DRIVER_NAME"
        "iHD"
      ];
      scripts = [pkgs.mpvScripts.uosc];
      config = lib.optionalAttrs hardwareDecodeEnabled {
        hwdec = "vaapi-copy";
        vaapi-device = cfg.hardwareDecodeDevice;
      };
    };
  };
}
