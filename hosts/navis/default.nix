{
  delib,
  inputs,
  ...
}:
delib.host {
  name = "navis";

  rice = "catppuccin-mocha";
  type = "desktop";

  nixos = {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.impermanence.nixosModules.impermanence
      inputs.nixos-facter-modules.nixosModules.facter
      inputs.chaotic.nixosModules.nyx-cache
      inputs.chaotic.nixosModules.nyx-overlay
      inputs.chaotic.nixosModules.nyx-registry
    ];

    nixpkgs.config.allowUnfree = true;

    facter.reportPath = ./facter.json;

    age = {
      secrets.passwd.file = ../../secrets/passwd.age;
      identityPaths = ["/persist/root/.ssh/id_ed25519"];
    };

    environment.persistence."/persist" = {
      hideMounts = true;

      files = ["/etc/machine-id"];

      directories = [
        "/etc/ssh"
        "/etc/NetworkManager"
        "/root/.ssh"
        "/var/lib/bluetooth"
        "/var/lib/iwd"
        "/var/lib/nixos"
        "/var/lib/systemd/coredump"
        "/var/lib/decky-loader"
        "/var/lib/libvirt"
      ];
    };
  };

  myconfig = {
    system = {
      boot.enable = true;
      chaotic.enable = true;
      environment.enable = true;
      filesystems.enable = true;
      fonts.enable = true;
      hardware.enable = true;
      i18n.enable = true;
      networking.enable = true;
      networking.hostName = "navis";
      nix.enable = true;
      programs.enable = true;
      security.enable = true;
      services.enable = true;
      users.enable = true;
    };

    home = {
      fish.enable = true;
      hyprland.enable = true;
      nix-index.enable = true;
      packages.enable = true;
      shell.enable = true;
      vicinae.enable = true;
      wezterm.enable = true;
    };

    programs = {
      cava.enable = true;
      draconisplusplus.enable = true;
      helium.enable = true;
      mpv.enable = true;
      quickshell.enable = true;
      xmobar.enable = true;

      git = {
        enable = true;
        credentialHelper = "libsecret";
        signingKey = "0FF5B8826803F895";
      };
    };
  };
}
