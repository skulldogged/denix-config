{
  config,
  delib,
  ...
}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    sops.secrets.cloudflare_token = {};

    services.cloudflared = {
      enable = true;
      tunnels = {
        "29205063-551c-44a0-9c85-c1c51f40a0d2" = {
          credentialsFile = config.sops.secrets.cloudflare_token.path;
          ingress = {
            "git.pupbrained.dev".service = "http://localhost:6610";
            "jellyfin.pupbrained.dev".service = "http://localhost:8096";
            "zip.pupbrained.dev".service = "http://localhost:3000";
            "sky.skulldogged.dev".service = "http://localhost:6969";
            "slskd.skulldogged.dev".service = "http://localhost:5030";
            "glance.skulldogged.dev".service = "http://localhost:5678";
            "home.skulldogged.dev".service = "http://127.0.0.1:8123";
            "cobalt.skulldogged.dev".service = "http://localhost:9001";
            "search.skulldogged.dev".service = "http://127.0.0.1:8888";
          };
          default = "http_status:404";
        };
      };
    };
  };
}
