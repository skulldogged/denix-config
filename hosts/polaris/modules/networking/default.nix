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
        nftables.enable = true;

        firewall = {
          backend = "nftables";
          checkReversePath = "loose";

          # LAN services are deliberately IPv4-only here. enX0 also has
          # globally routable IPv6 addresses, so interface-scoped rules would
          # expose these ports to the internet.
          extraInputRules = ''
            ip saddr ${lanIPv4} tcp dport { 22, 139, 445, 1883, 2022, 8096, 8123, 8443, 8920 } accept
            iifname "eno1" ip saddr ${lanIPv4} tcp dport 8686 accept
            ip saddr ${lanIPv4} udp dport { 137, 138, 1900, 7359, 60000-61000 } accept
          '';

          interfaces = {
            # Incus guests need the host-side dnsmasq listener for DNS and
            # DHCP, but do not otherwise get blanket access to host services.
            incusbr0 = {
              allowedTCPPorts = [53];
              allowedUDPPorts = [53 67];
            };

            tailscale0 = {
              allowedTCPPorts = [53 8443 8686];
              allowedUDPPorts = [53];
            };
          };
        };
      };
    };
  }
