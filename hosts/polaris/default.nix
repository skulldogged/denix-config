{
  delib,
  lib,
  ...
}:
delib.host {
  name = "polaris";

  system = "x86_64-linux";
  type = "server";

  nixos.networking = {
    useDHCP = lib.mkOverride 40 false;

    networkmanager = {
      settings.main.no-auto-default = "*";

      ensureProfiles.profiles.polaris-lan = {
        ethernet.mac-address = "38:22:E2:0C:1E:5A";

        connection = {
          id = "polaris-lan";
          type = "ethernet";
          autoconnect = true;
          autoconnect-priority = 100;
        };

        ipv4 = {
          addresses = "192.168.1.82/24";
          gateway = "192.168.1.1";
          dns = "1.1.1.1;1.0.0.1;";
          method = "manual";
        };

        ipv6 = {
          addr-gen-mode = "stable-privacy";
          method = "auto";
        };
      };
    };
  };

  myconfig = {
    polaris.enable = true;

    system = {
      environment.enable = true;
      hardware.enable = true;
      i18n.enable = true;
      nix.enable = true;
      programs.enable = true;
      security.enable = true;
      services.enable = true;
      stateversion.version = "23.11";

      boot = {
        disableFirmwareFramebuffer = true;
        enable = true;
        enableIommu = true;
      };

      networking = {
        enable = true;
        hostName = "polaris";
      };

      users = {
        enable = true;
        extraGroups = ["incus-admin" "kvm" "podman" "media"];
        linger = true;
      };
    };

    home = {
      fish.enable = true;
      nix-index.enable = true;
      packages.enable = true;
      shell.enable = true;
      t3code.enable = true;
    };

    programs = {
      bun.enable = true;
      draconisplusplus.enable = true;
      helium.enable = true;
      pi-coding-agent.enable = true;

      git = {
        enable = true;
        credentialHelper = "libsecret";
        signingKey = "6FB1AE28C81E4359";
      };
    };
  };
}
