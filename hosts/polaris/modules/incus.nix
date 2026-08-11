{
  delib,
  lib,
  pkgs,
  ...
}: let
  vmPortForwards = {
    incus-proxy-singularity-vnc = {
      listen = "127.0.0.1:15901";
      target = "10.90.0.47:5900";
    };
    incus-proxy-singularity-ssh = {
      listen = "127.0.0.1:12221";
      target = "10.90.0.47:22";
    };
    incus-proxy-win11-rdp = {
      listen = "127.0.0.1:13390";
      target = "10.90.0.123:3389";
    };
    incus-proxy-win11-ssh = {
      listen = "127.0.0.1:12222";
      target = "10.90.0.123:22";
    };
  };
in
  delib.module {
    name = "polaris";

    nixos.ifEnabled = {
      # The UHD 630 is dedicated to the Windows VM. Bind it to VFIO before i915
      # can reserve its MMIO BARs; dynamically detaching this boot GPU leaves a
      # PAT mapping behind and makes QEMU's VFIO accesses fail with ENOMEM.
      boot = {
        blacklistedKernelModules = ["i915"];
        initrd.kernelModules = ["vfio_pci"];
        kernelParams = ["vfio-pci.ids=8086:3e98"];
      };

      # Incus uses per-instance AppArmor profiles for additional isolation. The
      # kernel LSM becomes active after the next host reboot.
      security.apparmor.enable = true;

      # VM storage lives on the external POLARIS_DATA SSD. Refuse to start
      # Incus without that mount so /mnt/incus can never fall through to the
      # internal root filesystem when the USB drive is absent.
      systemd = {
        sockets =
          lib.mapAttrs (_: forward: {
            description = "Loopback listener for an Incus VM service";
            wantedBy = ["sockets.target"];
            listenStreams = [forward.listen];
          })
          vmPortForwards;

        services =
          {
            incus = {
              after = ["mnt.mount"];
              requires = ["mnt.mount"];
              unitConfig.ConditionPathIsMountPoint = "/mnt";
              preStart = ''
                ${pkgs.coreutils}/bin/install -d -o root -g root -m 0711 \
                  /mnt/incus/storage-pools/external-ssd
              '';
            };

            polaris-tailnet-vm-ports = {
              description = "Publish Incus VM services on the Polaris Tailscale address";
              after = ["network-online.target" "tailscaled.service"];
              wants = ["network-online.target"];
              requires = ["tailscaled.service"];
              wantedBy = ["multi-user.target"];
              path = [pkgs.tailscale];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                tailscale serve --bg --tcp=5901 tcp://127.0.0.1:15901
                tailscale serve --bg --tcp=2221 tcp://127.0.0.1:12221
                tailscale serve --bg --tcp=3390 tcp://127.0.0.1:13390
                tailscale serve --bg --tcp=2222 tcp://127.0.0.1:12222
              '';
              preStop = ''
                tailscale serve --tcp=5901 off || true
                tailscale serve --tcp=2221 off || true
                tailscale serve --tcp=3390 off || true
                tailscale serve --tcp=2222 off || true
              '';
            };
          }
          // lib.mapAttrs (_: forward: {
            description = "Forward a loopback socket to ${forward.target}";
            after = ["incus.service"];
            requires = ["incus.service"];
            serviceConfig = {
              ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${forward.target}";
              NoNewPrivileges = true;
              PrivateTmp = true;
            };
          })
          vmPortForwards;
      };

      virtualisation.incus = {
        enable = true;

        # Follow Incus's current monthly feature release rather than its LTS
        # channel. This is presently Incus 7.3 in the pinned nixpkgs input.
        # Incus 7.3's fast-reboot check compares /proc/<qemu-pid>/exe with the
        # QEMU launcher found in PATH. Nix's launcher execs a hidden wrapped
        # binary, so the paths always differ and Incus needlessly tears QEMU
        # down on every guest reboot. With a passed-through IGD, the immediate
        # reopen then races the VFIO reset and leaves the VM stopped.
        package = pkgs.incus.overrideAttrs (old: {
          patches = (old.patches or []) ++ [./incus-qemu-wrapper-fast-reboot.patch];
        });

        ui.enable = true;

        preseed = {
          config = {
            # IPv4-only keeps the API off the host's globally routed IPv6
            # addresses. The NixOS firewall restricts it to LAN and Tailscale.
            "core.https_address" = "0.0.0.0:8443";
          };

          networks = [
            {
              name = "incusbr0";
              type = "bridge";
              config = {
                "dns.domain" = "incus";
                "dns.mode" = "none";
                "dns.nameservers" = "10.100.0.53";
                "ipv4.address" = "10.90.0.1/24";
                "ipv4.nat" = "true";
                "ipv6.address" = "none";

                # Blocky already owns port 53 on Polaris. Keep Incus's dnsmasq
                # for DHCP, disable its DNS listener, and advertise Blocky above.
                "raw.dnsmasq" = "port=0";
              };
            }
          ];

          profiles = [
            {
              name = "default";
              description = "Polaris NAT network and external-SSD-backed root disk";
              devices = {
                eth0 = {
                  name = "eth0";
                  network = "incusbr0";
                  type = "nic";
                };

                root = {
                  path = "/";
                  pool = "external-ssd";
                  size = "32GiB";
                  type = "disk";
                };
              };
            }
            {
              name = "vm-small";
              description = "Small disposable VM: 2 vCPUs and 4 GiB RAM";
              config = {
                "limits.cpu" = "2";
                "limits.memory" = "4GiB";
              };
            }
            {
              name = "windows-11";
              description = "Windows 11 VM resources and virtual TPM 2.0";
              config = {
                "limits.cpu" = "6";
                "limits.memory" = "24GiB";
                "security.secureboot" = "true";
              };
              devices = {
                root = {
                  path = "/";
                  pool = "external-ssd";
                  size = "100GiB";
                  type = "disk";
                };
                tpm = {
                  type = "tpm";
                };
              };
            }
          ];

          storage_pools = [
            {
              name = "external-ssd";
              driver = "dir";
              config.source = "/mnt/incus/storage-pools/external-ssd";
            }
          ];
        };
      };
    };
  }
