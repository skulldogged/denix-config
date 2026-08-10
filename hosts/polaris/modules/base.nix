{
  config,
  delib,
  lib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  options.polaris = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    sops = {
      defaultSopsFile = ../../../secrets/polaris.yaml;
      age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    };

    time.timeZone = "America/New_York";

    nix.settings.trusted-users = lib.mkForce ["root"];

    users.users.${config.myconfig.constants.username}.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2vmQG3o3yMTXUbHYM7evCpUo/V+gK8Lofajt/hEjrB navis"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFve6rzQTu+icju0GGhuyVJ9QenCRHzRgjhyX5iNuinz"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLNLzoJDzuVhWZXuUO70Yj6bWg6t8kBFH0fWZIIwTC1w9w7Uv0ERuSBcp752fOpkm7fY5c2lyt12/ymEOParbhk= navis-tpm-polaris"
    ];

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

    programs.mosh = {
      enable = true;
      openFirewall = false;
    };

    security = {
      pam = {
        rssh.enable = true;

        services = {
          gdm.enableGnomeKeyring = true;
          sudo.rssh = true;
          sudo-i.rssh = true;
        };
      };

      sudo-rs.wheelNeedsPassword = lib.mkForce true;

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
