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
      zipline_secret = {};
    };

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
      bluesky-pds.serviceConfig.BindPaths = ["/mnt/pds"];
      zipline.serviceConfig.ReadWritePaths = ["/mnt/zipline"];
    };
  };
}
