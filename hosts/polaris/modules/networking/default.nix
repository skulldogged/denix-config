{delib, ...}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    networking = {
      networkmanager.dns = "none";
      dhcpcd.extraConfig = "nohook resolv.conf";
      resolvconf.enable = false;
      nameservers = ["127.0.0.1" "::1"];

      firewall = {
        checkReversePath = "loose";

        allowedTCPPorts = [
          22 # ssh
          2022 # eternal-terminal
          3000 # zipline
          4096 # opencode
          6610 # forgejo
          6969 # bluesky-pds
        ];

        interfaces.tailscale0 = {
          allowedTCPPorts = [53];
          allowedUDPPorts = [53];
        };
      };
    };
  };
}
