{
  config,
  delib,
  lib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    sops.secrets.vaultwarden_cloudflared_token = {
      sopsFile = ../../../../secrets/vaultwarden-cloudflared-token.yaml;
    };

    services.vaultwarden = {
      enable = true;
      domain = "vault.pupbrained.dev";

      config = {
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;

        # Preserve the current CoreOS instance's public configuration during
        # migration. This can be tightened after the cutover is verified.
        SIGNUPS_ALLOWED = true;
      };
    };

    # The remotely managed tunnel's origin is fixed at localhost:80. Keep the
    # privileged listener loopback-only and proxy it to native Vaultwarden.
    services.nginx = {
      enable = true;
      virtualHosts."vault.pupbrained.dev" = {
        default = true;
        listen = [
          {
            addr = "127.0.0.1";
            port = 80;
          }
          {
            addr = "[::1]";
            port = 80;
          }
        ];

        locations."/" = {
          proxyPass = "http://127.0.0.1:8222";
          proxyWebsockets = true;
        };
      };
    };

    systemd.services = {
      # The existing hostname uses a remotely managed Cloudflare tunnel. The
      # recovered connector preserves that hostname without a DNS change.
      vaultwarden-cloudflared = {
        description = "Cloudflare Tunnel for Vaultwarden";
        after = [
          "network-online.target"
          "vaultwarden.service"
        ];
        wants = ["network-online.target"];
        requires = ["vaultwarden.service"];
        wantedBy = ["multi-user.target"];

        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${lib.getExe pkgs.cloudflared} --no-autoupdate tunnel run --token-file %d/tunnel-token";
          LoadCredential = "tunnel-token:${config.sops.secrets.vaultwarden_cloudflared_token.path}";
          Restart = "on-failure";
          RestartSec = "5s";
          Type = "notify";
        };
      };
    };
  };
}
