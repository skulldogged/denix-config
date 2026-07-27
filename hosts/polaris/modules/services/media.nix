{
  config,
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    sops = {
      secrets = {
        slskd_api_key = {};
        slskd_env = {};
      };

      templates."slskd.yml" = {
        owner = "slskd";
        group = "media";
        mode = "0440";
        restartUnits = ["slskd.service"];
        content = ''
          directories:
            downloads: /mnt/music
          shares:
            directories:
              - /mnt/music
          feature:
            swagger: true
          transfers:
            download:
              slots: 5
          web:
            ip_address: 127.0.0.1
            port: 5030
            https:
              disabled: true
            authentication:
              apiKey: ${config.sops.placeholder.slskd_api_key}
        '';
      };
    };

    services = {
      jellyfin = {
        enable = true;
        openFirewall = false;
        dataDir = "/mnt/jellyfin";
        package = pkgs.local.jellyfin;
      };

      samba = {
        enable = true;
        openFirewall = false;
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

      slskd = {
        enable = true;
        openFirewall = true;
        package = pkgs.local.slskd;
        user = "slskd";
        group = "media";
        domain = null;
        environmentFile = config.sops.secrets.slskd_env.path;

        settings = {
          directories.downloads = "/mnt/music";
          feature.swagger = true;
          shares.directories = ["/mnt/music"];
          transfers.download.slots = 5;
          web = {
            ip_address = "127.0.0.1";
            https.disabled = true;
          };
        };
      };
    };

    systemd = {
      services = {
        jellyfin = {
          after = ["mnt.mount"];
          requires = ["mnt.mount"];
        };

        samba-smbd = {
          after = ["mnt.mount"];
          requires = ["mnt.mount"];
        };

        slskd = {
          after = ["mnt.mount"];
          requires = ["mnt.mount"];

          serviceConfig = {
            ExecStart = pkgs.lib.mkForce "${pkgs.local.slskd}/bin/slskd --app-dir /var/lib/slskd --config ${config.sops.templates."slskd.yml".path}";
            ReadOnlyPaths = pkgs.lib.mkForce [""];
            RuntimeDirectory = "slskd";
          };
        };
      };

      tmpfiles.rules = [
        "z /mnt 0755 root root - -"
        "d /mnt/music 2775 slskd media - -"
        "a /mnt/music - - - - g:media:rwx,d:g:media:rwx"
      ];
    };

    users = {
      groups.media = {};
      users.jellyfin.extraGroups = ["media"];
    };
  };
}
