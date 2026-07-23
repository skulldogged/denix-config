{
  delib,
  pkgs,
  ...
}: let
  cobalt = pkgs.callPackage ../../../../pkgs/cobalt/package.nix {};
in
  delib.module {
    name = "polaris";

    nixos.ifEnabled = {
      services = {
        caddy = {
          enable = true;
          globalConfig = ''
            auto_https off
            admin off
          '';
          extraConfig = ''
            :9001 {
              bind 127.0.0.1

              @api path /api /api/*
              handle @api {
                uri strip_prefix /api
                reverse_proxy 127.0.0.1:9000
              }

              handle /tunnel* {
                reverse_proxy 127.0.0.1:9000
              }

              handle {
                root * ${cobalt}/share/cobalt-web
                try_files {path} /404.html
                file_server
              }
            }
          '';
        };

        redis = {
          package = pkgs.valkey;
          servers.cobalt = {
            enable = true;
            bind = "127.0.0.1";
            port = 6379;
          };
        };
      };

      systemd.services = {
        caddy = {
          after = ["cobalt-api.service"];
          wants = ["cobalt-api.service"];
        };

        cobalt-api = {
          description = "cobalt API";
          wantedBy = ["multi-user.target"];
          after = ["network-online.target" "redis-cobalt.service"];
          wants = ["network-online.target"];
          requires = ["redis-cobalt.service"];

          environment = {
            API_URL = "https://cobalt.skulldogged.dev/";
            API_PORT = "9000";
            API_LISTEN_ADDRESS = "127.0.0.1";
            API_REDIS_URL = "redis://127.0.0.1:6379";
            CUSTOM_INNERTUBE_CLIENT = "TV_SIMPLY";
            YOUTUBE_GENERATE_PO_TOKENS = "1";
            YOUTUBE_USE_ONESIE = "1";
          };

          serviceConfig = {
            ExecStart = "${cobalt}/bin/cobalt-api";
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = 10;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = ["/var/lib/private/cobalt-api"];
            StateDirectory = "cobalt-api";
            WorkingDirectory = "/var/lib/private/cobalt-api";
          };
        };
      };
    };
  }
