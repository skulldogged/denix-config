{
  delib,
  inputs,
  pkgs,
  ...
}:
delib.module {
  name = "programs.cua-driver";

  options.programs.cua-driver = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    services.cua-driver = {
      enable = true;
      package = inputs.cua.packages.${pkgs.stdenv.hostPlatform.system}.cua-driver.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./cua-driver-hyprland.patch];
      });
    };

    # CUA uses AT-SPI to discover native Wayland application controls.
    services.gnome.at-spi2-core.enable = true;

    environment.sessionVariables = {
      # Native Wayland support is opt-in upstream.
      CUA_DRIVER_RS_ENABLE_WAYLAND = "1";

      # Nix owns upgrades, and product telemetry is unnecessary here.
      CUA_DRIVER_RS_TELEMETRY_ENABLED = "false";
      CUA_DRIVER_RS_UPDATE_CHECK = "false";
    };

    # Runtime fallbacks used by CUA's Wayland capture, input, and recording
    # implementations. ImageMagick is already supplied by the upstream module.
    environment.systemPackages = with pkgs; [
      ffmpeg
      glib
      grim
      wf-recorder
      wtype
    ];
  };
}
