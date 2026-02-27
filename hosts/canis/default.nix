{
  delib,
  pkgs,
  ...
}:
delib.host {
  name = "canis";

  type = "laptop";

  darwin = {
    # Allow unfree packages
    nixpkgs.config.allowUnfree = true;
    nixpkgs.hostPlatform = "aarch64-darwin";

    # macOS-specific settings
    ids.gids.nixbld = 30000;

    nix.buildMachines = [
      {
        hostName = "ssh.pupbrained.dev";
        protocol = "ssh-ng";
        sshUser = "nix-builder";
        sshKey = "/Users/marshall/.ssh/id_ed25519";
        systems = ["x86_64-linux"];
        maxJobs = 8;
        speedFactor = 10;
        supportedFeatures = [
          "nixos-test"
          "kvm"
          "recursive-nix"
          "big-parallel"
          "gccarch-x86-64-v4"
        ];
      }
    ];

    # Fonts
    fonts.packages = with pkgs; ([
        font-awesome
        inter
        maple-mono.Normal-NF
      ]
      ++ (with iosevka-comfy; [
        comfy
        comfy-duo
        comfy-fixed
        comfy-motion
        comfy-motion-duo
        comfy-motion-fixed
        comfy-wide
        comfy-wide-duo
        comfy-wide-fixed
        comfy-wide-motion
        comfy-wide-motion-duo
        comfy-wide-motion-fixed
      ]));

    # Networking
    networking = {
      computerName = "MacBook Air";
      hostName = "canis";
    };

    # System defaults
    system = {
      keyboard.enableKeyMapping = true;
      stateVersion = 5;
      primaryUser = "marshall";

      defaults = {
        NSGlobalDomain = {
          KeyRepeat = 1;
          NSAutomaticCapitalizationEnabled = false;
          NSAutomaticSpellingCorrectionEnabled = false;
        };
      };
    };

    # Touch ID for sudo
    security.pam.services.sudo_local.touchIdAuth = true;
  };

  myconfig = {
    # System modules
    system.nix.enable = true;
    system.programs.enable = true;

    # Home modules
    home.shell.enable = true;
    home.fish.enable = true;
    home.packages.enable = true;
    home.wezterm.enable = true;

    # Programs
    programs.git.enable = true;
    programs.git.credentialHelper = "osxkeychain";
    programs.git.signingKey = "874E22DF2F9DFCB5";
    programs.draconisplusplus.enable = true;
  };
}
