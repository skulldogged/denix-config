{
  delib,
  inputs,
  lib,
  ...
}:
delib.host {
  name = "spacebot-droplet";

  type = "server";

  nixos = {
    imports = [
      inputs.nixos-facter-modules.nixosModules.facter
      (inputs.nixpkgs + "/nixos/modules/profiles/qemu-guest.nix")
    ];

    facter.reportPath = ./facter.json;

    nix = {
      distributedBuilds = true;
      buildMachines = [
        {
          hostName = "polaris-nix";
          protocol = "ssh-ng";
          sshUser = "nix-builder";
          sshKey = "/root/.ssh/id_ed25519";
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSU9tTitBZGZTSW03L1pla3dzV0IvYytpZFBZRnJ2QlVqZEhTMWkzUDRPRSsgcm9vdEBwb2xhcmlzLW5peAo=";
          systems = ["x86_64-linux"];
          maxJobs = 8;
          speedFactor = 10;
          supportedFeatures = [
            "nixos-test"
            "kvm"
            "recursive-nix"
            "big-parallel"
            "gccarch-x86-64-v4"
          ];
        }
      ];
    };

    boot = {
      loader.grub.device = "/dev/vda";
      tmp.cleanOnBoot = true;

      initrd = {
        availableKernelModules = [
          "ata_piix"
          "uhci_hcd"
          "xen_blkfront"
          "vmw_pvscsi"
        ];
        kernelModules = ["nvme"];
      };
    };

    fileSystems."/" = {
      device = "/dev/vda1";
      fsType = "ext4";
    };

    networking = {
      domain = "";
      hostName = "spacebot-droplet";

      nameservers = ["8.8.8.8"];
      defaultGateway = "174.138.48.1";

      useDHCP = lib.mkOverride 0 false;
      usePredictableInterfaceNames = lib.mkForce false;

      dhcpcd.enable = false;
      networkmanager.enable = lib.mkForce false;

      interfaces = {
        eth0 = {
          ipv4.addresses = [
            {
              address = "174.138.62.248";
              prefixLength = 20;
            }
            {
              address = "10.17.0.5";
              prefixLength = 16;
            }
          ];

          ipv6.addresses = [
            {
              address = "fe80::e84b:4ff:fe13:ec50";
              prefixLength = 64;
            }
          ];

          ipv4.routes = [
            {
              address = "174.138.48.1";
              prefixLength = 32;
            }
          ];
        };

        eth1 = {
          ipv4.addresses = [
            {
              address = "10.108.0.3";
              prefixLength = 20;
            }
          ];

          ipv6.addresses = [
            {
              address = "fe80::bf:7aff:fea8:a8cb";
              prefixLength = 64;
            }
          ];
        };
      };
    };

    services.udev.extraRules = ''
      ATTR{address}=="ea:4b:04:13:ec:50", NAME="eth0"
      ATTR{address}=="02:bf:7a:a8:a8:cb", NAME="eth1"
    '';

    services.tailscale = {
      enable = true;
      openFirewall = true;
    };

    users.users.marshall.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB7fPGt6KAzwOVQqOV0JT74unUXDbdQHvD3yufYyvLKW mars@navis-win"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBsHqYKt58eFcZo7UdPX45CaEhLeGge+cE1Gdt74IHSv MacBook"
    ];

    zramSwap.enable = true;
  };

  myconfig = {
    system = {
      boot.enable = true;
      environment.enable = true;
      hardware.enable = true;
      i18n.enable = true;
      networking = {
        enable = true;
        hostName = "spacebot-droplet";
      };
      nix.enable = true;
      programs.enable = true;
      security.enable = true;
      services.enable = true;
      stateversion.version = "23.11";
      users.enable = true;
    };

    home = {
      fish.enable = true;
      nix-index.enable = true;
      packages.enable = true;
      shell.enable = true;
    };

    programs.git = {
      enable = true;
      credentialHelper = "libsecret";
      signingKey = "91B1F40056A01DDF";
    };
  };
}
