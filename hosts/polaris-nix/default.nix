{
  delib,
  inputs,
  pkgs,
  ...
}:
delib.host {
  name = "polaris-nix";

  type = "server";

  nixos = {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.nixos-facter-modules.nixosModules.facter
    ];

    # Allow unfree packages
    nixpkgs.config.allowUnfree = true;

    # Facter hardware detection
    facter.reportPath = ./facter.json;

    # Agenix secrets
    age = {
      identityPaths = ["/root/.ssh/id_ed25519"];

      secrets = {
        cloudflare_token.file = ../../secrets/cloudflare_token.age;
        forgejo_token.file = ../../secrets/forgejo_token.age;
        mailer_passwd.file = ../../secrets/mailer_passwd.age;
        slskd_env.file = ../../secrets/slskd_env.age;
        zipline_secret.file = ../../secrets/zipline_secret.age;
      };
    };

    # Custom filesystems
    fileSystems = {
      "/" = {
        device = "/dev/disk/by-uuid/64079eb2-d3e3-47b7-a889-d5b2fee4fa82";
        fsType = "ext4";
      };

      "/boot" = {
        device = "/dev/disk/by-uuid/BC12-6397";
        fsType = "vfat";
      };

      "/mnt" = {
        device = "/dev/xvdb";
        fsType = "ext4";
        options = ["nofail"];
      };
    };

    swapDevices = [{device = "/dev/disk/by-uuid/d36507db-7392-4852-9b2a-12d2a476cd31";}];

    # Time zone
    time.timeZone = "America/New_York";

    # Server-specific packages
    environment.systemPackages = with pkgs; [
      miniupnpc
      nodejs_20
      codeium
    ];

    # Server-specific boot settings
    boot = {
      binfmt.emulatedSystems = ["aarch64-linux"];
      kernelPackages = pkgs.linuxPackages_xanmod_latest;
    };
  };

  myconfig = {
    # System modules
    system.boot.enable = true;
    system.boot.bootloader = "systemd-boot";
    system.environment.enable = true;
    system.hardware.enable = true;
    system.i18n.enable = true;
    system.networking.enable = true;
    system.networking.hostName = "polaris-nix";
    system.nix.enable = true;
    system.programs.enable = true;
    system.security.enable = true;
    system.stateversion.version = "23.11";
    system.users.enable = true;
    system.users.extraGroups = ["kvm" "podman"];

    # Server services
    services.server.enable = true;
  };
}
