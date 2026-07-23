{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    services = {
      resolved.enable = false;

      blocky = {
        enable = true;
        settings = {
          ports.dns = 53;
          customDNS = {
            customTTL = "1h";
            mapping = {
              "voice.skulldogged.dev" = "192.168.1.82";
            };
          };
          upstreams.groups.default = [
            "194.242.2.2"
            "2a07:e340::2"
          ];
          blocking = {
            denylists = {
              ads = [
                "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
                "https://big.oisd.nl/"
                ''
                  saawsedge.com
                ''
              ];
              tracking = [
                "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling/hosts"
                "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/tif.txt"
              ];
              malware = [
                "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/malicious.txt"
                "https://urlhaus.abuse.ch/downloads/hostfile/"
              ];
            };
            clientGroupsBlock.default = ["ads" "tracking" "malware"];
          };
          caching = {
            minTime = "5m";
            maxTime = "30m";
            prefetching = true;
          };
        };
      };
    };

    systemd.services = {
      polaris-blocky-service-ip = {
        wantedBy = ["multi-user.target"];
        before = ["tailscaled-set.service"];
        after = ["network.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${pkgs.iproute2}/bin/ip address add 10.100.0.53/32 dev lo 2>/dev/null || true
        '';
        postStop = ''
          ${pkgs.iproute2}/bin/ip address del 10.100.0.53/32 dev lo 2>/dev/null || true
        '';
      };

      polaris-local-resolvconf = {
        wantedBy = ["multi-user.target"];
        after = ["blocky.service" "tailscaled-set.service"];
        requires = ["blocky.service"];
        serviceConfig.Type = "oneshot";
        script = ''
          printf 'nameserver 127.0.0.1\nnameserver ::1\n' > /etc/resolv.conf
        '';
      };
    };
  };
}
