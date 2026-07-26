{
  config,
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  options.polaris = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    nixpkgs.config.permittedInsecurePackages = [
      "pnpm-9.15.9"
    ];

    sops = {
      defaultSopsFile = ../../../secrets/polaris.yaml;
      age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    };

    time.timeZone = "America/New_York";

    environment = {
      systemPackages = with pkgs; [
        bento4
        codeium
        ffmpeg
        ghostty.terminfo
        graalvmPackages.graalvm-oracle_17
        nodejs_24
        opencode
        uv
      ];

      sessionVariables.BROWSER = "helium";
    };

    services = {
      desktopManager.plasma6.enable = true;
      displayManager.sddm.enable = true;

      eternal-terminal.enable = true;
      protonmail-bridge.enable = true;
      xe-guest-utilities.enable = true;
    };

    virtualisation = {
      containers.enable = true;
      docker.enable = false;

      podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };

    programs.mosh.enable = true;

    security = {
      pam.services.gdm.enableGnomeKeyring = true;

      sudo.extraRules = [
        {
          users = [config.myconfig.constants.username];
          commands = [
            {
              command = "/run/current-system/sw/bin/podman";
              options = ["NOPASSWD"];
            }
          ];
        }
      ];
    };
  };
}
