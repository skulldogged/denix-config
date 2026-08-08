{delib, ...}:
delib.host {
  name = "polaris";

  system = "x86_64-linux";
  type = "server";

  myconfig = {
    polaris.enable = true;

    system = {
      environment.enable = true;
      hardware.enable = true;
      i18n.enable = true;
      nix.enable = true;
      programs.enable = true;
      security.enable = true;
      services.enable = true;
      stateversion.version = "23.11";

      boot.enable = true;

      networking = {
        enable = true;
        hostName = "polaris";
      };

      users = {
        enable = true;
        extraGroups = ["kvm" "podman" "media"];
      };
    };

    home = {
      fish.enable = true;
      nix-index.enable = true;
      packages.enable = true;
      shell.enable = true;
      t3code.enable = true;
    };

    programs = {
      bun.enable = true;
      draconisplusplus.enable = true;
      helium.enable = true;
      pi-coding-agent.enable = true;

      git = {
        enable = true;
        credentialHelper = "libsecret";
        signingKey = "6FB1AE28C81E4359";
      };
    };
  };
}
