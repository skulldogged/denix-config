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
      agenix.nixosModules.default
      nixos-facter-modules.nixosModules.facter
      helium-services.nixosModules.default
      vscode-server.nixosModules.default
    ];

    nixpkgs.config.allowUnfree = true;

    facter.reportPath = ./facter.json;

    age = {
      identityPaths = ["/root/.ssh/id_ed25519"];

      secrets = {
        bsky_pds.file = ../../secrets/bsky_pds.age;
        cloudflare_token.file = ../../secrets/cloudflare_token.age;
        forgejo_token.file = ../../secrets/forgejo_token.age;
        helium_hmac.file = ../../secrets/helium_hmac.age;
        mailer_passwd.file = ../../secrets/mailer_passwd.age;
        slskd_env.file = ../../secrets/slskd_env.age;
        zipline_secret.file = ../../secrets/zipline_secret.age;
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

    environment.systemPackages =
      [inputs.agenix.packages.${pkgs.system}.default]
      ++ (with pkgs; [
        codeium
        graalvmPackages.graalvm-oracle_17
        miniupnpc
        nodejs_20
      ]);

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
      jellyfin.enable = true;
      jellyfin.dataDir = "/mnt/jellyfin";
      mullvad-vpn.enable = true;
      tailscale.enable = true;
      xe-guest-utilities.enable = true;
      vscode-server.enable = true;

      bluesky-pds = {
        enable = true;
        pdsadmin.enable = true;
        environmentFiles = [config.age.secrets.bsky_pds.path];

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
          "c9bd4d77-2b10-4880-8c79-9c970f08cbd8" = {
            credentialsFile = config.age.secrets.cloudflare_token.path;
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

        secrets.mailer.PASSWD = config.age.secrets.mailer_passwd.path;

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

      gitea-actions-runner = {
        package = pkgs.forgejo-runner;
        instances.default = {
          enable = true;
          name = "main";
          url = "https://git.pupbrained.dev";
          tokenFile = config.age.secrets.forgejo_token.path;
          labels = [
            "ubuntu-24.04:docker://catthehacker/ubuntu:act-latest"
            "native-linux:host"
          ];
          settings = {
            cache = {
              enabled = true;
              dir = "/var/cache/forgejo-runner";
            };
          };
        };
      };

      glance = {
        enable = true;
        settings = {
          server = {
            host = "0.0.0.0";
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
        hmacSecretFile = config.age.secrets.helium_hmac.path;
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
        domain = null;
        environmentFile = config.age.secrets.slskd_env.path;

        settings = {
          directories.downloads = "/mnt/music";
          shares.directories = ["/mnt/music"];
        };
      };

      zipline = {
        enable = true;
        environmentFiles = [config.age.secrets.zipline_secret.path];
        settings = {
          CORE_HOSTNAME = "0.0.0.0";
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
        slskd.serviceConfig.ReadOnlyPaths = pkgs.lib.mkForce [""];
        zipline.serviceConfig.ReadWritePaths = ["/mnt/zipline"];
      };
    };

    users = {
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
      oci-containers.backend = "podman";
      oci-containers.containers = {
        yt-session-generator = {
          image = "ghcr.io/imputnet/yt-session-generator:webserver";
          extraOptions = ["--network=host" "--shm-size=2gb" "--security-opt=seccomp=unconfined"];
          autoStart = true;
        };
      };

      podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };

    networking = {
      networkmanager.dns = "none";
      dhcpcd.extraConfig = "nohook resolv.conf";
      resolvconf.enable = false;
      nameservers = ["9.9.9.10" "9.9.9.9"];
    };

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
        extraGroups = ["kvm" "podman"];
      };
    };

    home = {
      fish.enable = true;
      nix-index.enable = true;
      packages.enable = true;
      shell.enable = true;
    };

    programs = {
      draconisplusplus.enable = true;

      git = {
        enable = true;
        credentialHelper = "libsecret";
        signingKey = "91B1F40056A01DDF";
      };
    };
  };
}
