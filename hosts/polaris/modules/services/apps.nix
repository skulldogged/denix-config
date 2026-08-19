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

        settings = {
          search.formats = [
            "html"
            "json"
          ];

          server = {
            bind_address = "127.0.0.1";
            # SearXNG's built-in limiter allows only four non-HTML API
            # requests per client per hour, which is unsuitable for Pi's
            # JSON search integration.  Keep exposure controlled by the
            # loopback bind and Cloudflare Tunnel instead.
            limiter = false;
            port = 8888;
            secret_key = "$SEARX_SECRET_KEY";
          };
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
