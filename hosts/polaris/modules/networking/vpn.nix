{
  config,
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    sops.secrets.mullvad_private_key = {
      owner = "root";
      mode = "0400";
    };

    services.tailscale = {
      enable = true;
      extraSetFlags = ["--accept-dns=false" "--advertise-exit-node" "--advertise-routes=10.100.0.53/32"];
      openFirewall = true;
      useRoutingFeatures = "server";
    };

    # Traffic accepted by this proxy becomes Polaris-originated traffic, so
    # it follows the normal ISP route instead of the wg-mullvad policy route
    # used for packets forwarded from Tailscale clients.
    services.microsocks = {
      enable = true;
      ip = "100.92.239.38";
      port = 1080;
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [1080];

    systemd.services.microsocks = {
      after = ["tailscaled.service"];
      requires = ["tailscaled.service"];
    };

    networking.wireguard.interfaces.wg-mullvad = {
      ips = [
        "10.65.182.233/32"
        "fc00:bbbb:bbbb:bb01::2:b6e8/128"
      ];
      privateKeyFile = config.sops.secrets.mullvad_private_key.path;
      table = "51820";

      peers = [
        {
          # Mullvad us-uyk-wg-202, Secaucus NJ.
          publicKey = "8Rh2Qc+vXTREhJb/RfCcpXS13U9xSqy4Pnw4+Wwt7iE=";
          allowedIPs = ["0.0.0.0/0" "::/0"];
          endpoint = "104.36.50.33:51820";
          persistentKeepalive = 25;
        }
      ];

      postSetup = ''
        ${pkgs.iproute2}/bin/ip rule add to 194.242.2.2/32 table 51820 priority 9999 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip -6 rule add to 2a07:e340::2/128 table 51820 priority 9999 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip rule add from 100.64.0.0/10 table 51820 priority 10000 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip -6 rule add from fd7a:115c:a1e0::/48 table 51820 priority 10000 2>/dev/null || true
        ${pkgs.iptables}/bin/iptables -t nat -C PREROUTING -i tailscale0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null \
          || ${pkgs.iptables}/bin/iptables -t nat -A PREROUTING -i tailscale0 -p udp --dport 53 -j REDIRECT --to-ports 53
        ${pkgs.iptables}/bin/iptables -t nat -C PREROUTING -i tailscale0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null \
          || ${pkgs.iptables}/bin/iptables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 53 -j REDIRECT --to-ports 53
        ${pkgs.iptables}/bin/ip6tables -t nat -C PREROUTING -i tailscale0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null \
          || ${pkgs.iptables}/bin/ip6tables -t nat -A PREROUTING -i tailscale0 -p udp --dport 53 -j REDIRECT --to-ports 53
        ${pkgs.iptables}/bin/ip6tables -t nat -C PREROUTING -i tailscale0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null \
          || ${pkgs.iptables}/bin/ip6tables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 53 -j REDIRECT --to-ports 53
        ${pkgs.iptables}/bin/iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -o wg-mullvad -j MASQUERADE 2>/dev/null \
          || ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -o wg-mullvad -j MASQUERADE
        ${pkgs.iptables}/bin/ip6tables -t nat -C POSTROUTING -s fd7a:115c:a1e0::/48 -o wg-mullvad -j MASQUERADE 2>/dev/null \
          || ${pkgs.iptables}/bin/ip6tables -t nat -A POSTROUTING -s fd7a:115c:a1e0::/48 -o wg-mullvad -j MASQUERADE
      '';

      postShutdown = ''
        ${pkgs.iproute2}/bin/ip rule del to 194.242.2.2/32 table 51820 priority 9999 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip -6 rule del to 2a07:e340::2/128 table 51820 priority 9999 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip rule del from 100.64.0.0/10 table 51820 priority 10000 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip -6 rule del from fd7a:115c:a1e0::/48 table 51820 priority 10000 2>/dev/null || true
        ${pkgs.iptables}/bin/iptables -t nat -D PREROUTING -i tailscale0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
        ${pkgs.iptables}/bin/iptables -t nat -D PREROUTING -i tailscale0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
        ${pkgs.iptables}/bin/ip6tables -t nat -D PREROUTING -i tailscale0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
        ${pkgs.iptables}/bin/ip6tables -t nat -D PREROUTING -i tailscale0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
        ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o wg-mullvad -j MASQUERADE 2>/dev/null || true
        ${pkgs.iptables}/bin/ip6tables -t nat -D POSTROUTING -s fd7a:115c:a1e0::/48 -o wg-mullvad -j MASQUERADE 2>/dev/null || true
      '';
    };
  };
}
