{delib, ...}:
delib.host {
  name = "navis";

  rice = "catppuccin-mocha";
  system = "x86_64-linux";
  type = "desktop";

  myconfig = {
    navis.enable = true;

    system = {
      boot = {
        enable = true;
        enableIntelGraphics = true;
      };

      environment.enable = true;
      fonts.enable = true;
      hardware.enable = true;
      i18n.enable = true;
      networking.enable = true;
      networking.hostName = "navis";
      nix.enable = true;
      programs.enable = true;
      security.enable = true;
      services.enable = true;
      users.enable = true;
      users.extraGroups = ["tss"];
    };

    home = {
      fish.enable = true;
      hyprland.enable = true;
      nix-index.enable = true;
      packages.enable = true;
      shell.enable = true;
      ghostty.enable = true;
    };

    programs = {
      agent-github.enable = true;
      bun.enable = true;
      cava.enable = true;
      codex-desktop.enable = true;
      crash-diagnosis.enable = true;
      cua-driver.enable = true;
      pi-coding-agent.enable = true;
      herdr.enable = true;
      draconisplusplus.enable = true;
      helium.enable = true;
      mpv = {
        enable = true;
        hardwareDecodeDevice = "/dev/dri/by-path/pci-0000:00:02.0-render";
      };
      mpd.enable = true;
      rmpc.enable = true;
      caelestia-shell.enable = true;

      git = {
        enable = true;
        credentialHelper = "libsecret";
        signingKey = "263409D620072FB8";
      };

      ranni-wallpaper = {
        enable = true;
        engineAssetsRoot = "/mnt/Shared/SteamLibrary/steamapps/common/wallpaper_engine/assets";
        scenePackage = "/mnt/Shared/SteamLibrary/steamapps/workshop/content/431960/2847826034/scene.pkg";
      };
    };
  };
}
