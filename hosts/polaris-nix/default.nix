{
  delib,
  inputs,
  pkgs,
  config,
  ...
}:
delib.host {
  name = "polaris-nix";

  type = "server";

  nixos = {
    imports = with inputs; [
      sops-nix.nixosModules.sops
      nixos-facter-modules.nixosModules.facter
      helium-services.nixosModules.default
      vscode-server.nixosModules.default
    ];

    nixpkgs.config.allowUnfree = true;
    nixpkgs.overlays = [inputs.nix-openclaw.overlays.default];

    facter.reportPath = ./facter.json;

    sops = {
      defaultSopsFile = ../../secrets/polaris-nix.yaml;
      age.sshKeyPaths = ["/root/.ssh/id_ed25519"];

      secrets = {
        bsky_pds = {};
        cloudflare_token = {};
        forgejo_token = {};
        helium_hmac = {};
        mailer_passwd = {};
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

    swapDevices = [{device = "/dev/disk/by-uuid/d36507db-7392-4852-9b2a-12d2a476cd31";}];

    time.timeZone = "America/New_York";

    environment.systemPackages = with pkgs; [
      codeium
      graalvmPackages.graalvm-oracle_17
      miniupnpc
      nodejs_20
    ];

    boot = {
      binfmt.emulatedSystems = ["aarch64-linux"];
      kernelPackages = pkgs.linuxPackages_xanmod_latest;
      loader.systemd-boot.enable = true;
    };

    services = {
      resolved.enable = false;

      desktopManager.plasma6.enable = true;
      displayManager.sddm.enable = true;

      eternal-terminal.enable = true;
      tailscale.enable = true;
      tailscale.openFirewall = true;
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
            HTTP_ADDR = "127.0.0.1";
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
              ];
              tracking = [
                "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling/hosts"
              ];
            };
            clientGroupsBlock = {
              default = ["ads" "tracking"];
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

      helium-services = {
        enable = true;
        hostname = "skulldogged.dev";
        hmacSecretFile = config.sops.secrets.helium_hmac.path;
      };

      jellyfin = {
        enable = true;
        openFirewall = true;
        dataDir = "/mnt/jellyfin";
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

    systemd.services = {
      bluesky-pds.serviceConfig.BindPaths = ["/mnt/pds"];
      zipline.serviceConfig.ReadWritePaths = ["/mnt/zipline"];

      slskd = {
        serviceConfig = {
          ExecStart = pkgs.lib.mkForce "${pkgs.slskd}/bin/slskd --app-dir /var/lib/slskd --config ${config.sops.templates."slskd.yml".path}";
          ReadOnlyPaths = pkgs.lib.mkForce [""];
          RuntimeDirectory = "slskd";
        };
      };
    };

    users = {
      groups.media = {};

      users.git = {
        isSystemUser = true;
        useDefaultShell = true;
        group = "git";
        home = config.services.forgejo.stateDir;
      };

      groups.git = {};
    };

    virtualisation = {
      containers.enable = true;

      podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };

    networking = {
      firewall.allowedTCPPorts = [
        22 # ssh
        2022 # eternal-terminal
        3000 # zipline
        6610 # forgejo
        6969 # bluesky-pds
        8081 # helium-services nginx
      ];
      networkmanager.dns = "none";
      dhcpcd.extraConfig = "nohook resolv.conf";
      resolvconf.enable = false;
      nameservers = ["9.9.9.10" "9.9.9.9"];
    };

    systemd.tmpfiles.rules = [
      "d /mnt/music 2775 root media - -"
      "A /mnt/music - - - - d:g:media:rwx,d:o::rx,d:m::rwx,g:media:rwX,o::rX,m::rwX"
    ];

    security.pam.services.gdm.enableGnomeKeyring = true;
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
        hostName = "polaris-nix";
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
      openclaw.enable = true;
      draconisplusplus.enable = true;

      git = {
        enable = true;
        credentialHelper = "libsecret";
        signingKey = "91B1F40056A01DDF";
      };
    };
  };
}
