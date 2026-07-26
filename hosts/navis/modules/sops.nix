{delib, ...}:
delib.module {
  name = "navis";

  nixos.ifEnabled = {
    sops = {
      defaultSopsFile = ../../../secrets/navis.yaml;
      age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

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
