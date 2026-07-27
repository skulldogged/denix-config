{delib, ...}:
delib.module {
  name = "navis";

  nixos.ifEnabled = {
    sops = {
      defaultSopsFile = ../../../secrets/navis.yaml;
      # Activation runs before impermanence bind-mounts /persist/etc/ssh at
      # /etc/ssh, so read the persisted host identity directly.
      age.sshKeyPaths = ["/persist/etc/ssh/ssh_host_ed25519_key"];

      secrets = {
        cifs = {};
        passwd = {};
        zipline_token = {
          owner = "marshall";
        };
      };
    };
  };
}
