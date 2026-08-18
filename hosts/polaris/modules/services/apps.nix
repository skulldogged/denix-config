{
  config,
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    sops.secrets = {
      bsky_pds = {};
      searxng_secret = {};
      zipline_secret = {};
    };

    sops.templates."searxng.env".content = ''
      SEARX_SECRET_KEY=${config.sops.placeholder.searxng_secret}
    '';

    services = {
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

      searx = {
        enable = true;
        environmentFile = config.sops.templates."searxng.env".path;
        redisCreateLocally = true;

        settings = {
          search.formats = [
            "html"
            "json"
          ];

          server = {
            bind_address = "127.0.0.1";
            limiter = true;
            port = 8888;
            secret_key = "$SEARX_SECRET_KEY";
          };
        };

        limiterSettings.botdetection = {
          ipv4_prefix = 32;
          ipv6_prefix = 56;
          trusted_proxies = [
            "127.0.0.0/8"
            "::1"
          ];
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
          UPLOADER_MAX_SIZE = "1GB";
          CORE_MAX_SIZE = "1GB";
          CORE_CHUNKED_MAX_SIZE = "1GB";
        };
      };
    };

    systemd.services = {
      bluesky-pds = {
        after = ["mnt.mount"];
        requires = ["mnt.mount"];
        serviceConfig.BindPaths = ["/mnt/pds"];
      };

      zipline = {
        after = ["mnt.mount"];
        requires = ["mnt.mount"];
        serviceConfig.ReadWritePaths = ["/mnt/zipline"];
      };
    };
  };
}
