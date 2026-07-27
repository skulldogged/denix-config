{delib, ...}: let
  lanIPv4 = "192.168.1.0/24";
in
  delib.module {
    name = "polaris";

    nixos.ifEnabled = {
      services.openssh.openFirewall = false;

      networking = {
        networkmanager.dns = "none";
        dhcpcd.extraConfig = "nohook resolv.conf";
        resolvconf.enable = false;
        nameservers = ["127.0.0.1" "::1"];

        firewall = {
          checkReversePath = "loose";

          # LAN services are deliberately IPv4-only here. enX0 also has
          # globally routable IPv6 addresses, so interface-scoped rules would
          # expose these ports to the internet.
          extraCommands = ''
            iptables -w -A nixos-fw -s ${lanIPv4} -p tcp -m multiport \
              --dports 22,139,445,1883,2022,8096,8123,8920 \
              -j nixos-fw-accept
            iptables -w -A nixos-fw -s ${lanIPv4} -p udp -m multiport \
              --dports 137,138,1900,7359 \
              -j nixos-fw-accept
            iptables -w -A nixos-fw -s ${lanIPv4} -p udp \
              --dport 60000:61000 \
              -j nixos-fw-accept
          '';

          interfaces.tailscale0 = {
            allowedTCPPorts = [53];
            allowedUDPPorts = [53];
          };
        };
      };
    };
  }
