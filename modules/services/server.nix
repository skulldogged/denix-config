{
  delib,
  pkgs,
  config,
  ...
}:
delib.module {
  name = "services.server";

  options.services.server = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    services = {
      # Desktop environment for server
      desktopManager.plasma6.enable = true;
      displayManager.sddm.enable = true;

      # Server services
      eternal-terminal.enable = true;
      jellyfin.enable = true;
      jellyfin.dataDir = "/mnt/jellyfin";
      mullvad-vpn.enable = true;
      tailscale.enable = true;
      xe-guest-utilities.enable = true;

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

      # DNS resolution disabled in favor of custom nameservers
      resolved.enable = false;

      # Cloudflare tunnel
      cloudflared = {
        enable = true;
        tunnels = {
          "c9bd4d77-2b10-4880-8c79-9c970f08cbd8" = {
            credentialsFile = config.age.secrets.cloudflare_token.path;
            default = "http_status:404";
          };
        };
      };

      # Forgejo Git hosting
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

      # Forgejo Actions Runner
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

      helium-services = {
        enable = true;
        hostname = "skulldogged.dev";
        hmacSecretFile = config.age.secrets.helium_hmac.path;
      };

      # qBittorrent
      qbittorrent = {
        enable = true;

        serverConfig = {
          LegalNotice.Accepted = true;

          Preferences = {
            WebUI = {
              AlternativeUIEnabled = true;
              RootFolder = "${pkgs.vuetorrent}/share/vuetorrent";

              Username = "mars";
              Password_PBKDF2 = "K/xm0Byb8Iq2d4QI/yYpow==:52QryAiEcyZ3uxxT11R2dCkWFeG0nU/Z0Qd4Z//VbddM6YlYwKwgWyALcTbIpD4wfxSBwejyxz4bsmBqCKm1eg==";
            };

            General.Locale = "en";
          };
        };
      };

      # Samba file sharing
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
        };
      };

      samba-wsdd.enable = false;

      # Soulseek daemon
      slskd = {
        enable = true;
        domain = null;
        environmentFile = config.age.secrets.slskd_env.path;

        settings = {
          directories.downloads = "/mnt/music";
          shares.directories = ["/mnt/music"];

          web.authentication.api_keys.local = {
            key = "sAA1Uj25ghNJ4jTh23+IbmktGzX5mZGdZSG3IlOMtg0=";
            role = "Administrator";
            cidr = "127.0.0.1/32";
          };
        };
      };

      # Wastebin pastebin
      wastebin = {
        enable = true;
        settings.WASTEBIN_BASE_URL = "https://bin.pupbrained.dev";
      };

      # Zipline file upload
      zipline = {
        enable = true;
        environmentFiles = [config.age.secrets.zipline_secret.path];
        settings = {
          CORE_HOSTNAME = "0.0.0.0";
          DATASOURCE_LOCAL_DIRECTORY = "/mnt/zipline";
        };
      };
    };

    # Custom systemd services
    systemd = {
      services = {
        bluesky-pds.serviceConfig.BindPaths = ["/mnt/pds"];
        slskd.serviceConfig.ReadOnlyPaths = pkgs.lib.mkForce [""];

        slskd-api-rescan = {
          description = "Trigger slskd share rescan via HTTP API";
          preStart = ''
            echo "Waiting for slskd to start..."
            sleep 5
          '';
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.curl}/bin/curl -X POST -H 'Authorization: sAA1Uj25ghNJ4jTh23+IbmktGzX5mZGdZSG3IlOMtg0=' http://127.0.0.1:5030/api/shares/rescan";
          };
          after = ["slskd.service"];
          requires = ["slskd.service"];
          wantedBy = ["multi-user.target"];
        };

        zipline.serviceConfig.ReadWritePaths = ["/mnt/zipline"];
      };

      timers.slskd-api-rescan = {
        description = "Periodic slskd API rescan trigger";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*/30 * * * *";
          Persistent = true;
        };
      };
    };

    # Git user for Forgejo
    users = {
      users.git = {
        isSystemUser = true;
        useDefaultShell = true;
        group = "git";
        home = config.services.forgejo.stateDir;
      };

      groups.git = {};
    };

    # Virtualisation
    virtualisation = {
      containers.enable = true;

      podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };

    # Custom networking for server
    networking = {
      networkmanager.dns = "none";
      dhcpcd.extraConfig = "nohook resolv.conf";
      resolvconf.enable = false;
      nameservers = ["9.9.9.10" "9.9.9.9"];
    };

    # Security - PAM gnome keyring for GDM (doesn't conflict with ssh.startAgent)
    security.pam.services.gdm.enableGnomeKeyring = true;
  };
}
