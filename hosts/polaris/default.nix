{
  delib,
  inputs,
  pkgs,
  config,
  ...
}: let
  codexDesktop = inputs.codex-desktop-linux.packages.${pkgs.stdenv.hostPlatform.system}.codex-desktop-computer-use-ui-remote-mobile-control;
  codexAuthSwitch = pkgs.writeShellScriptBin "codex-auth-switch" ''
    set -euo pipefail

    primary_account="admin@skulldogged.dev"
    fallback_account="root@skulldogged.dev"

    if [ "$#" -gt 0 ]; then
      ${pkgs.bun}/bin/bunx --bun codex-auth switch "$@"
    else
      active_account="$(${pkgs.bun}/bin/bunx --bun codex-auth list --skip-api | ${pkgs.gawk}/bin/awk '$1 == "*" { print $3; exit }')"

      case "$active_account" in
        "$primary_account")
          next_account="$fallback_account"
          ;;
        "$fallback_account")
          next_account="$primary_account"
          ;;
        "")
          echo "Could not detect the active Codex account." >&2
          exit 1
          ;;
        *)
          echo "Active Codex account '$active_account' is not one of the configured toggle accounts." >&2
          exit 1
          ;;
      esac

      echo "Switching Codex account: $active_account -> $next_account"
      ${pkgs.bun}/bin/bunx --bun codex-auth switch "$next_account"
    fi

    ${pkgs.systemd}/bin/systemctl --user restart-or-try-reload codex-desktop.service || \
      ${pkgs.systemd}/bin/systemctl --user start codex-desktop.service
  '';
in
  delib.host {
    name = "polaris";

    type = "server";

    nixos = {
      imports = with inputs; [
        sops-nix.nixosModules.sops
        nix-minecraft.nixosModules.minecraft-servers
        nixos-facter-modules.nixosModules.facter
        aurelia.nixosModules.default
        vscode-server.nixosModules.default
      ];

      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = [inputs.nix-minecraft.overlay];

      facter.reportPath = ./facter.json;

      nix = {
        distributedBuilds = true;

        buildMachines = [
          {
            hostName = "136.243.173.22";
            protocol = "ssh-ng";
            sshUser = "marshall";
            sshKey = "/home/marshall/.ssh/id_ed25519";
            publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUNYQU9oYzRERUJQOVU2emFqNElkT2JtM09xNk1GWFdKanZuR1dtU08wVUc=";
            systems = ["x86_64-linux"];
            maxJobs = 8;
            speedFactor = 1;
            supportedFeatures = [
              "benchmark"
              "big-parallel"
              "kvm"
              "nixos-test"
            ];
          }
        ];

        nixPath = ["nixpkgs=${inputs.nixpkgs}"];

        registry.nixpkgs.flake = inputs.nixpkgs;
      };

      programs.ssh.knownHosts."136.243.173.22".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICXAOhc4DEBP9U6zaj4IdObm3Oq6MFXWJjvnGWmSO0UG";

      sops = {
        defaultSopsFile = ../../secrets/polaris.yaml;
        age.sshKeyPaths = ["/root/.ssh/id_ed25519"];

        secrets = {
          bsky_pds = {};
          cloudflare_token = {};
          forgejo_token = {};
          jellyfin_api_key = {};
          mailer_passwd = {};
          mullvad_private_key = {
            owner = "root";
            mode = "0400";
          };
          slskd_api_key = {};
          slskd_env = {};
          zipline_secret = {};
        };

        templates."slskd.yml" = {
          owner = "slskd";
          group = "media";
          mode = "0440";
          content = ''
            directories:
              downloads: /mnt/music
            shares:
              directories:
                - /mnt/music
            feature:
              swagger: true
            global:
              download:
                slots: 5
            web:
              port: 5030
              authentication:
                apiKey: ${config.sops.placeholder.slskd_api_key}
          '';
        };
      };

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

      time.timeZone = "America/New_York";

      environment.systemPackages = with pkgs; [
        bento4
        codeium
        ffmpeg
        ghostty.terminfo
        graalvmPackages.graalvm-oracle_17
        miniupnpc
        nodejs_24
        opencode
        uv
        codexDesktop
        codexAuthSwitch
      ];

      environment.sessionVariables.BROWSER = "helium";

      boot = {
        binfmt.emulatedSystems = ["aarch64-linux"];
        kernelPackages = pkgs.linuxPackages_xanmod_latest;
        loader.systemd-boot.enable = true;
      };

      services = {
        resolved.enable = false;

        minecraft-servers = {
          enable = false;
          dataDir = "/mnt/minecraft";
          eula = true;
          openFirewall = true;

          servers.fabulously-optimized = let
            fetchedMods = pkgs.fetchModrinthMods ./mc-server/mods.lock.json;
            localMods = ./mc-server/mods;
          in {
            enable = true;
            jvmOpts = "-Xms2G -Xmx16G";
            package = pkgs.fabricServers.fabric-1_21_11.override {
              jre_headless = pkgs.jdk25_headless;
            };

            symlinks.mods = pkgs.runCommandNoCC "polaris-minecraft-mods" {} ''
              mkdir -p "$out"
              ln -s ${fetchedMods}/* "$out"/
              ln -s ${localMods}/* "$out"/
            '';
          };
        };

        desktopManager.plasma6.enable = true;
        displayManager.sddm.enable = true;

        eternal-terminal.enable = true;
        protonmail-bridge.enable = true;
        tailscale.enable = true;
        tailscale.extraSetFlags = ["--advertise-exit-node"];
        tailscale.openFirewall = true;
        tailscale.useRoutingFeatures = "server";
        xe-guest-utilities.enable = true;
        vscode-server.enable = true;

        bluesky-pds = {
          enable = true;
          pdsadmin.enable = true;
          environmentFiles = [config.sops.secrets.bsky_pds.path];

          settings = {
            PDS_BLOBSTORE_DISK_LOCATION = "/mnt/pds/blocks";
            PDS_DATA_DIRECTORY = "/mnt/pds";
            PDS_HOSTNAME = "sky.skulldogged.dev";
            PDS_PORT = 6969;
          };
        };

        cloudflared = {
          enable = true;
          tunnels = {
            "29205063-551c-44a0-9c85-c1c51f40a0d2" = {
              credentialsFile = config.sops.secrets.cloudflare_token.path;
              ingress = {
                "git.pupbrained.dev" = {
                  service = "http://localhost:6610";
                };
                "jellyfin.pupbrained.dev" = {
                  service = "http://localhost:8096";
                };
                "zip.pupbrained.dev" = {
                  service = "http://localhost:3000";
                };
                "sky.skulldogged.dev" = {
                  service = "http://localhost:6969";
                };
                "services.skulldogged.dev" = {
                  service = "http://localhost:8081";
                };
                "slskd.skulldogged.dev" = {
                  service = "http://localhost:5030";
                };
                "glance.skulldogged.dev" = {
                  service = "http://localhost:5678";
                };
                "mc.skulldogged.dev" = {
                  service = "tcp://localhost:25565";
                };
                "lyrics.skulldogged.dev" = {
                  service = "http://localhost:8083";
                };
                "identity.skulldogged.dev" = {
                  service = "http://localhost:8080";
                };
              };
              default = "http_status:404";
            };
          };
        };

        forgejo = let
          forgejoDomain = "git.pupbrained.dev";
        in {
          enable = true;
          package = pkgs.forgejo;
          user = "git";
          group = "git";
          lfs.enable = true;

          secrets.mailer.PASSWD = config.sops.secrets.mailer_passwd.path;

          settings = {
            log.LEVEL = "Debug";
            DEFAULT.APP_NAME = "MarGit";

            actions = {
              ENABLED = true;
              DEFAULT_ACTIONS_URL = "github";
            };

            database = {
              SQLITE_JOURNAL_MODE = "WAL";
              LOG_SQL = false;
            };

            federation.ENABLED = true;

            mailer = {
              ENABLED = true;
              SMTP_ADDR = "email-smtp.us-east-2.amazonaws.com";
              FROM = "noreply@git.pupbrained.dev";
              USER = "AKIAVIRH7PRQXI3FCBZ4";
              SEND_AS_PLAIN_TEXT = true;
            };

            metrics = {
              ENABLED = true;
              ENABLED_ISSUE_BY_REPOSITORY = true;
              ENABLED_ISSUE_BY_LABEL = true;
            };

            oauth2_client = {
              ACCOUNT_LINKING = "login";
              USERNAME = "nickname";
              ENABLE_AUTO_REGISTRATION = false;
              REGISTER_EMAIL_CONFIRM = false;
              UPDATE_AVATAR = true;
            };

            packages.ENABLED = true;

            repository = {
              DEFAULT_PRIVATE = "private";
              ENABLE_PUSH_CREATE_USER = true;
              ENABLE_PUSH_CREATE_ORG = true;
            };

            server = {
              HTTP_ADDR = "0.0.0.0";
              HTTP_PORT = 6610;
              DOMAIN = forgejoDomain;
              ROOT_URL = "https://${forgejoDomain}/";
              SSH_USER = "git";
              SSH_DOMAIN = "ssh.pupbrained.dev";
            };

            service = {
              DISABLE_REGISTRATION = true;
              SHOW_REGISTRATION_BUTTON = false;
              REGISTER_EMAIL_CONFIRM = false;
              ENABLE_NOTIFY_MAIL = true;
            };

            session.COOKIE_SECURE = true;
            ui.DEFAULT_THEME = "forgejo-auto";
            "ui.meta".AUTHOR = "MarGit";
          };
        };

        blocky = {
          enable = true;
          settings = {
            ports.dns = 53;
            customDNS = {
              customTTL = "1h";
              mapping = {
                "voice.skulldogged.dev" = "192.168.1.82";
              };
            };
            upstream.default = [
              "9.9.9.9"
              "149.112.112.112"
              "9.9.9.10"
              "149.112.112.10"
            ];
            blocking = {
              blackLists = {
                ads = [
                  "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
                  "https://big.oisd.nl/"
                  ''
                    saawsedge.com
                  ''
                ];
                tracking = [
                  "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling/hosts"
                  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/tif.txt"
                ];
                malware = [
                  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/malicious.txt"
                  "https://urlhaus.abuse.ch/downloads/hostfile/"
                ];
              };
              clientGroupsBlock = {
                default = ["ads" "tracking" "malware"];
              };
            };
            caching = {
              minTime = "5m";
              maxTime = "30m";
              prefetching = true;
            };
          };
        };

        gatus = {
          enable = true;
          openFirewall = true;
          settings = {
            web = {
              port = 8082;
            };
            storage = {
              type = "memory";
            };
            endpoints = [
              {
                name = "Jellyfin";
                url = "https://jellyfin.pupbrained.dev";
                conditions = ["[STATUS] == 200"];
                interval = "5m";
              }
              {
                name = "Forgejo";
                url = "https://git.pupbrained.dev";
                conditions = ["[STATUS] == 200"];
                interval = "5m";
              }
              {
                name = "Bluesky PDS";
                url = "https://sky.skulldogged.dev";
                conditions = ["[STATUS] == 200"];
                interval = "5m";
              }
              {
                name = "Glance";
                url = "http://127.0.0.1:5678";
                conditions = ["[STATUS] == 200"];
                interval = "5m";
              }
              {
                name = "Zipline";
                url = "http://127.0.0.1:3000";
                conditions = ["[STATUS] == 200"];
                interval = "5m";
              }
              {
                name = "slskd";
                url = "http://127.0.0.1:5030";
                conditions = ["[STATUS] == 200"];
                interval = "5m";
              }
              {
                name = "Aurelia";
                url = "http://127.0.0.1:8083";
                conditions = ["[STATUS] == 200"];
                interval = "5m";
              }
              {
                name = "Blocky DNS";
                url = "udp://127.0.0.1:53";
                conditions = ["[CONNECTED] == true"];
                interval = "1m";
              }
              {
                name = "Tailscale";
                url = "udp://100.92.239.38:41641";
                conditions = ["[CONNECTED] == true"];
                interval = "1m";
              }
            ];
          };
        };

        glance = {
          enable = true;
          openFirewall = true;
          settings = {
            server = {
              host = "127.0.0.1";
              port = 5678;
            };

            theme = {
              background-color = "240 21 15";
              negative-color = "347 70 65";
              positive-color = "115 54 76";
              primary-color = "217 92 83";
            };

            pages = [
              {
                name = "Startpage";
                width = "slim";
                hide-desktop-navigation = true;
                center-vertically = true;
                columns = [
                  {
                    size = "full";
                    widgets = [
                      {
                        type = "search";
                        autofocus = true;
                      }

                      {
                        type = "monitor";
                        cache = "1m";
                        title = "Services";
                        sites = [
                          {
                            title = "Jellyfin";
                            url = "https://jellyfin.pupbrained.dev/";
                            icon = "si:jellyfin";
                          }
                          {
                            title = "Forgejo";
                            url = "https://git.pupbrained.dev/";
                            icon = "si:forgejo";
                          }
                          {
                            title = "Vaultwarden";
                            url = "https://vault.pupbrained.dev/";
                            icon = "si:vaultwarden";
                          }
                        ];
                      }

                      {
                        type = "bookmarks";
                        groups = [
                          {
                            title = "General";
                            links = [
                              {
                                title = "Gmail";
                                url = "https://mail.google.com/mail/u/0/";
                              }
                              {
                                title = "Amazon";
                                url = "https://www.amazon.com/";
                              }
                              {
                                title = "Github";
                                url = "https://github.com/";
                              }
                            ];
                          }
                          {
                            title = "Entertainment";
                            links = [
                              {
                                title = "YouTube";
                                url = "https://www.youtube.com/";
                              }
                              {
                                title = "Prime Video";
                                url = "https://www.primevideo.com/";
                              }
                              {
                                title = "Disney+";
                                url = "https://www.disneyplus.com/";
                              }
                            ];
                          }
                          {
                            title = "Social";
                            links = [
                              {
                                title = "Reddit";
                                url = "https://www.reddit.com/";
                              }
                              {
                                title = "Twitter";
                                url = "https://twitter.com/";
                              }
                              {
                                title = "Instagram";
                                url = "https://www.instagram.com/";
                              }
                            ];
                          }
                        ];
                      }
                    ];
                  }
                ];
              }
            ];
          };
        };

        aurelia-sidecar-daemon = {
          enable = true;
          package = inputs.aurelia.packages.${pkgs.stdenv.hostPlatform.system}.aurelia-sidecar-daemon;
          environmentFile = config.sops.secrets.jellyfin_api_key.path;
          openFirewall = true;
          settings = {
            bind = "0.0.0.0";
            jellyfin_url = "http://localhost:8096";
            music_paths = ["/mnt/music"];
            port = 8083;
          };
        };

        jellyfin = {
          enable = true;
          openFirewall = true;
          dataDir = "/mnt/jellyfin";
          package = let
            fetchNupkg = pkgs.callPackage (inputs.nixpkgs + "/pkgs/build-support/dotnet/fetch-nupkg") {
              patchNupkgs = pkgs.dotnetCorePackages.patchNupkgs;
              nugetPackageHook = pkgs.dotnetCorePackages.nugetPackageHook;
            };
            jellyfin-web = pkgs.jellyfin-web.overrideAttrs (old: {
              version = "12.0.0";
              src = inputs.jellyfin-web-src;
              npmDeps = pkgs.fetchNpmDeps {
                src = inputs.jellyfin-web-src;
                name = "jellyfin-web-12.0.0-npm-deps";
                hash = "sha256-JmxFiPfQLqJB5iO+pjt7eH0/ip8hSI9euzhl69yEU08=";
              };
              postPatch =
                (old.postPatch or "")
                + ''
                  substituteInPlace package.json \
                    --replace-fail '"node": ">=24.0.0"' '"node": ">=22.0.0"' \
                    --replace-fail '"npm": ">=11.0.0"' '"npm": ">=10.0.0"'
                '';
            });
          in
            (pkgs.jellyfin.override {
              inherit jellyfin-web;
              dotnetCorePackages =
                pkgs.dotnetCorePackages
                // {
                  sdk_9_0 = pkgs.dotnetCorePackages.sdk_10_0;
                  aspnetcore_9_0 = pkgs.dotnetCorePackages.aspnetcore_10_0;
                };
            }).overrideAttrs (old: {
              version = "12.0.0";
              src = inputs.jellyfin-src;
              nugetDeps = ./jellyfin-nuget-deps.json;
              buildInputs =
                (old.buildInputs or [])
                ++ (map fetchNupkg (pkgs.lib.importJSON ./jellyfin-nuget-deps.json));
            });
        };

        qbittorrent = {
          enable = false;

          serverConfig = {
            LegalNotice.Accepted = true;

            Preferences = {
              WebUI = {
                AlternativeUIEnabled = true;
                RootFolder = "${pkgs.vuetorrent}/share/vuetorrent";
                Port = 8090;

                Username = "mars";
                Password_PBKDF2 = "K/xm0Byb8Iq2d4QI/yYpow==:52QryAiEcyZ3uxxT11R2dCkWFeG0nU/Z0Qd4Z//VbddM6YlYwKwgWyALcTbIpD4wfxSBwejyxz4bsmBqCKm1eg==";
              };

              General.Locale = "en";
            };
          };
        };

        samba = {
          enable = true;
          openFirewall = true;
          nmbd.enable = false;

          settings = {
            music = {
              path = "/mnt/music";
              browseable = "yes";
              "read only" = "no";
              "guest ok" = "no";
              "create mask" = "0664";
              "directory mask" = "0775";
              "valid users" = "marshall";
            };

            gamesaves = {
              path = "/mnt/saves";
              browseable = "yes";
              "read only" = "no";
              "guest ok" = "no";
              "create mask" = "0664";
              "directory mask" = "0775";
              "valid users" = "marshall";
            };
          };
        };

        samba-wsdd.enable = false;

        slskd = {
          enable = true;
          openFirewall = true;
          user = "slskd";
          group = "media";
          domain = null;
          environmentFile = config.sops.secrets.slskd_env.path;

          settings = {
            directories.downloads = "/mnt/music";
            feature.swagger = true;
            shares.directories = ["/mnt/music"];
            global.download.slots = 5;
          };
        };

        zipline = {
          enable = true;
          package = pkgs.zipline.overrideAttrs (_: {
            buildPhase = ''
              runHook preBuild
              pnpm build
              runHook postBuild
            '';
          });
          environmentFiles = [config.sops.secrets.zipline_secret.path];
          settings = {
            CORE_HOSTNAME = "127.0.0.1";
            CORE_PORT = 3000;
            DATASOURCE_LOCAL_DIRECTORY = "/mnt/zipline";
            UPLOADER_MAX_SIZE = "100MB";
            CORE_MAX_SIZE = "100MB";
            CORE_CHUNKED_MAX_SIZE = "100MB";
          };
        };
      };

      systemd = {
        services = {
          bluesky-pds.serviceConfig.BindPaths = ["/mnt/pds"];
          zipline.serviceConfig.ReadWritePaths = ["/mnt/zipline"];
          aurelia-sidecar-daemon.environment.RUST_LOG = "debug";

          renew-voicechat-upnp = {
            description = "Renew UPnP mapping for Simple Voice Chat";
            after = ["network-online.target"];
            wants = ["network-online.target"];

            serviceConfig = {
              Type = "oneshot";
              ExecStart = ''
                ${pkgs.miniupnpc}/bin/upnpc -u http://192.168.1.1:36163/rootDesc.xml -a 192.168.1.82 24454 24454 udp 3600
              '';
            };
          };

          slskd = {
            serviceConfig = {
              ExecStart = pkgs.lib.mkForce "${pkgs.slskd}/bin/slskd --app-dir /var/lib/slskd --config ${config.sops.templates."slskd.yml".path}";
              ReadOnlyPaths = pkgs.lib.mkForce [""];
              RuntimeDirectory = "slskd";
            };
          };
        };

        timers.renew-voicechat-upnp = {
          description = "Periodically renew UPnP mapping for Simple Voice Chat";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = "10m";
            Unit = "renew-voicechat-upnp.service";
          };
        };
      };

      users = {
        groups.media = {};

        users = {
          jellyfin.extraGroups = ["media"];

          git = {
            isSystemUser = true;
            useDefaultShell = true;
            group = "git";
            home = config.services.forgejo.stateDir;
          };

          nix-builder = {
            isNormalUser = true;
            openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB7fPGt6KAzwOVQqOV0JT74unUXDbdQHvD3yufYyvLKW mars@navis-win"
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBsHqYKt58eFcZo7UdPX45CaEhLeGge+cE1Gdt74IHSv MacBook"
            ];
          };
        };

        groups.git = {};
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

      networking = {
        firewall.checkReversePath = "loose";
        firewall.allowedTCPPorts = [
          22 # ssh
          2022 # eternal-terminal
          3000 # zipline
          4096 # opencode
          6610 # forgejo
          6969 # bluesky-pds
        ];
        firewall.allowedUDPPorts = [
          24454 # simple voice chat
        ];
        networkmanager.dns = "none";
        dhcpcd.extraConfig = "nohook resolv.conf";
        resolvconf.enable = false;
        nameservers = ["9.9.9.10" "9.9.9.9"];

        wireguard.interfaces.wg-mullvad = {
          ips = [
            "10.65.182.233/32"
            "fc00:bbbb:bbbb:bb01::2:b6e8/128"
          ];
          privateKeyFile = config.sops.secrets.mullvad_private_key.path;
          table = "51820";

          peers = [
            {
              publicKey = "IzqkjVCdJYC1AShILfzebchTlKCqVCt/SMEXolaS3Uc=";
              allowedIPs = ["0.0.0.0/0" "::/0"];
              endpoint = "143.244.47.65:51820";
              persistentKeepalive = 25;
            }
          ];

          postSetup = ''
            ${pkgs.iproute2}/bin/ip rule add from 100.64.0.0/10 table 51820 priority 10000 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip -6 rule add from fd7a:115c:a1e0::/48 table 51820 priority 10000 2>/dev/null || true
            ${pkgs.iptables}/bin/iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -o wg-mullvad -j MASQUERADE 2>/dev/null \
              || ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -o wg-mullvad -j MASQUERADE
            ${pkgs.iptables}/bin/ip6tables -t nat -C POSTROUTING -s fd7a:115c:a1e0::/48 -o wg-mullvad -j MASQUERADE 2>/dev/null \
              || ${pkgs.iptables}/bin/ip6tables -t nat -A POSTROUTING -s fd7a:115c:a1e0::/48 -o wg-mullvad -j MASQUERADE
          '';

          postShutdown = ''
            ${pkgs.iproute2}/bin/ip rule del from 100.64.0.0/10 table 51820 priority 10000 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip -6 rule del from fd7a:115c:a1e0::/48 table 51820 priority 10000 2>/dev/null || true
            ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o wg-mullvad -j MASQUERADE 2>/dev/null || true
            ${pkgs.iptables}/bin/ip6tables -t nat -D POSTROUTING -s fd7a:115c:a1e0::/48 -o wg-mullvad -j MASQUERADE 2>/dev/null || true
          '';
        };
      };

      systemd.tmpfiles.rules = [
        "z /mnt 0755 root root - -"
        "d /mnt/music 2775 slskd media - -"
        "a /mnt/music - - - - g:media:rwx,d:g:media:rwx"
      ];

      security.pam.services.gdm.enableGnomeKeyring = true;

      security.sudo.extraRules = [
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

    home.systemd.user.services.codex-desktop = {
      Unit = {
        Description = "Codex Desktop";
        After = ["graphical-session.target"];
        PartOf = ["graphical-session.target"];
      };

      Service = {
        Type = "simple";
        ExecStart = "${codexDesktop}/bin/codex-desktop";
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install.WantedBy = ["graphical-session.target"];
    };

    myconfig = {
      system = {
        environment.enable = true;
        hardware.enable = true;
        i18n.enable = true;
        nix.enable = true;
        programs.enable = true;
        security.enable = true;
        services.enable = true;
        stateversion.version = "23.11";

        boot.enable = true;

        networking = {
          enable = true;
          hostName = "polaris";
        };

        users = {
          enable = true;
          extraGroups = ["kvm" "podman" "media"];
        };
      };

      home = {
        fish.enable = true;
        nix-index.enable = true;
        packages.enable = true;
        shell.enable = true;
      };

      programs = {
        bun.enable = true;
        draconisplusplus.enable = true;
        helium.enable = true;

        git = {
          enable = true;
          credentialHelper = "libsecret";
          signingKey = "6FB1AE28C81E4359";
        };
      };
    };
  }
