{
  config,
  delib,
  inputs,
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

    services = {
      jellyfin = {
        enable = true;
        openFirewall = true;
        dataDir = "/mnt/jellyfin";
        package = pkgs.callPackage ../../../../pkgs/jellyfin/package.nix {
          inherit inputs pkgs;
          nugetDepsFile = ../../jellyfin-nuget-deps.json;
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
    };

    systemd = {
      services.slskd.serviceConfig = {
        ExecStart = pkgs.lib.mkForce "${pkgs.slskd}/bin/slskd --app-dir /var/lib/slskd --config ${config.sops.templates."slskd.yml".path}";
        ReadOnlyPaths = pkgs.lib.mkForce [""];
        RuntimeDirectory = "slskd";
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
