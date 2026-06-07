{
  config,
  delib,
  inputs,
  lib,
  pkgs,
  ...
}: let
  headscaleDomain = "headscale.skulldogged.dev";
  headplaneDomain = "headplane.skulldogged.dev";
in
  delib.host {
    name = "hetzner";
    type = "server";

    nixos = {
      imports = [inputs.codex-desktop-linux.nixosModules.default];

      nixpkgs.config.allowUnfree = true;
      nixpkgs.hostPlatform = "x86_64-linux";
      fileSystems = {
        "/" = {
          device = "/dev/disk/by-uuid/e5bf912e-e898-4acc-8e73-baddbc7b6022";
          fsType = "ext4";
        };
        "/boot" = {
          device = "/dev/disk/by-uuid/0DC8-9D1A";
          fsType = "vfat";
        };
      };
      boot = {
        initrd.availableKernelModules = ["nvme" "xhci_pci" "ahci" "usbhid" "sd_mod"];
        kernelModules = ["kvm-amd"];
        loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };
      };
      hardware = {
        cpu.amd.updateMicrocode = true;
        enableRedistributableFirmware = true;
      };
      networking = {
        hostName = "hetzner";
        useDHCP = false;
        useNetworkd = true;
        nameservers = ["185.12.64.1" "185.12.64.2" "2a01:4ff:ff00::add:2" "2a01:4ff:ff00::add:1"];
        firewall = {
          allowedTCPPorts = [22 80 443 2222];
          allowedUDPPortRanges = [
            {
              from = 60000;
              to = 61999;
            }
          ];
          extraCommands = ''
            iptables -C FORWARD -i enp6s0 -o virbr0 -p tcp -d 192.168.122.82 --dport 22 -j ACCEPT 2>/dev/null \
              || iptables -I FORWARD 1 -i enp6s0 -o virbr0 -p tcp -d 192.168.122.82 --dport 22 -j ACCEPT
            iptables -t nat -C PREROUTING -i enp6s0 -p udp --dport 61000:61999 -j DNAT --to-destination 192.168.122.82 2>/dev/null \
              || iptables -t nat -I PREROUTING 1 -i enp6s0 -p udp --dport 61000:61999 -j DNAT --to-destination 192.168.122.82
            iptables -C FORWARD -i enp6s0 -o virbr0 -p udp -d 192.168.122.82 --dport 61000:61999 -j ACCEPT 2>/dev/null \
              || iptables -I FORWARD 1 -i enp6s0 -o virbr0 -p udp -d 192.168.122.82 --dport 61000:61999 -j ACCEPT
          '';
          extraStopCommands = ''
            iptables -D FORWARD -i enp6s0 -o virbr0 -p tcp -d 192.168.122.82 --dport 22 -j ACCEPT 2>/dev/null || true
            iptables -t nat -D PREROUTING -i enp6s0 -p udp --dport 61000:61999 -j DNAT --to-destination 192.168.122.82 2>/dev/null || true
            iptables -D FORWARD -i enp6s0 -o virbr0 -p udp -d 192.168.122.82 --dport 61000:61999 -j ACCEPT 2>/dev/null || true
          '';
        };
        nat = {
          enable = true;
          externalInterface = "enp6s0";
          internalInterfaces = ["virbr0"];
          forwardPorts = [
            {
              destination = "192.168.122.82:22";
              proto = "tcp";
              sourcePort = 2222;
            }
          ];
        };
      };
      systemd.network.networks."40-enp6s0" = {
        matchConfig.Name = "enp6s0";
        networkConfig = {
          DHCP = "no";
          Address = ["37.27.111.236/32" "2a01:4f9:3070:2256::2/64"];
          DNS = ["185.12.64.1" "185.12.64.2" "2a01:4ff:ff00::add:2" "2a01:4ff:ff00::add:1"];
        };
        routes = [
          {
            Gateway = "37.27.111.193";
            GatewayOnLink = true;
          }
          {
            Gateway = "fe80::1";
            GatewayOnLink = true;
          }
        ];
      };
      services = {
        openssh = {
          enable = true;
          settings = {
            KbdInteractiveAuthentication = false;
            PasswordAuthentication = false;
            PermitRootLogin = "no";
            PubkeyAuthentication = true;
          };
        };
        headscale = {
          enable = true;
          settings = {
            server_url = "https://${headscaleDomain}";
            dns = {
              base_domain = "tail.skulldogged.dev";
              nameservers.global = ["10.100.0.53"];
            };
          };
        };
        headplane = {
          enable = true;
          settings = {
            server = {
              base_url = "https://${headplaneDomain}";
              cookie_secret_path = "/var/lib/headplane/cookie_secret";
            };
            headscale = {
              public_url = "https://${headscaleDomain}";
            };
          };
        };
        nginx = {
          enable = true;
          recommendedGzipSettings = true;
          recommendedOptimisation = true;
          recommendedProxySettings = true;
          recommendedTlsSettings = true;
          virtualHosts = {
            ${headscaleDomain} = {
              enableACME = true;
              forceSSL = true;
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString config.services.headscale.port}";
                proxyWebsockets = true;
              };
            };
            ${headplaneDomain} = {
              enableACME = true;
              forceSSL = true;
              locations."/".proxyPass = "http://${config.services.headplane.settings.server.host}:${toString config.services.headplane.settings.server.port}";
            };
          };
        };
        tailscale = {
          enable = true;
          extraSetFlags = ["--accept-dns=false"];
        };
      };
      systemd.services.headplane.preStart = ''
        secret=/var/lib/headplane/cookie_secret
        if [ ! -s "$secret" ]; then
          umask 077
          ${pkgs.coreutils}/bin/head -c 32 /dev/urandom \
            | ${pkgs.coreutils}/bin/base64 \
            | ${pkgs.coreutils}/bin/tr -dc 'A-Za-z0-9' \
            | ${pkgs.coreutils}/bin/head -c 32 > "$secret"
        fi
        ${pkgs.coreutils}/bin/chmod 600 "$secret"
      '';
      security.acme = {
        acceptTerms = true;
        defaults.email = "admin@skulldogged.dev";
      };
      users = {
        mutableUsers = true;
        users.marshall = {
          isNormalUser = true;
          shell = pkgs.fish;
          linger = true;
          extraGroups = ["wheel" "libvirtd" "kvm"];
          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINauytpggm6187T/fjWhS2p1Z9GGbO0TmiuIn6Z92nj marshall@DESKTOP-1OD2LVU"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB7fPGt6KAzwOVQqOV0JT74unUXDbdQHvD3yufYyvLKW mars@navis-win"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHZwiMID2oMCujOBMiD2gg0MrzE9N1O348jS1sQTBvmc"
          ];
        };
        users.nix-builder = {
          isNormalUser = true;
          shell = pkgs.fish;
          openssh.authorizedKeys.keys = config.users.users.marshall.openssh.authorizedKeys.keys;
        };
        users.nixbuilder = {
          isNormalUser = true;
          shell = pkgs.fish;
          openssh.authorizedKeys.keys = config.users.users.marshall.openssh.authorizedKeys.keys;
        };
      };
      security.sudo-rs = {
        enable = true;
        wheelNeedsPassword = false;
        execWheelOnly = true;
      };
      nix = {
        daemonCPUSchedPolicy = "batch";
        daemonIOSchedClass = "idle";
        daemonIOSchedPriority = 7;
        gc = {
          automatic = true;
          dates = "weekly";
          options = "--delete-older-than 14d";
        };
        optimise.automatic = true;
        settings = {
          experimental-features = ["nix-command" "flakes" "recursive-nix"];
          trusted-users = ["root" "marshall" "nix-builder" "nixbuilder" "@wheel"];
          allowed-users = ["root" "marshall" "nix-builder" "nixbuilder" "@wheel"];
          max-jobs = 8;
          cores = 0;
          builders-use-substitutes = true;
          min-free = 10737418240;
          max-free = 53687091200;
          system-features = ["benchmark" "big-parallel" "gccarch-x86-64-v4" "kvm" "nixos-test" "recursive-nix"];
        };
      };
      virtualisation.libvirtd = {
        enable = true;
        qemu = {
          package = pkgs.qemu_kvm;
          runAsRoot = false;
          swtpm.enable = true;
        };
      };
      environment.systemPackages = with pkgs; [cloud-utils curl efibootmgr git gptfdisk htop jq mosh pciutils qemu_kvm tmux usbutils vim wget codex];

      programs.codexDesktopLinux = {
        enable = true;
        remoteMobileControl.enable = true;
        remoteControl = {
          enable = true;
          package = pkgs.codex;
        };
      };
    };

    myconfig = {
      system = {
        environment.enable = true;
        nix.enable = lib.mkForce false;
        programs.enable = true;
        stateversion.version = "26.05";
      };
      home = {
        fish.enable = true;
        nix-index.enable = true;
        packages.enable = true;
        shell.enable = true;
      };
      programs.draconisplusplus.enable = true;
      programs.git = {
        enable = true;
        credentialHelper = "cache";
      };
    };
  }
