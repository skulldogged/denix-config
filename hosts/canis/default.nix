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

    # macOS-specific settings
    ids.gids.nixbld = 30000;

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

    # skhd keybindings
    services.skhd = {
      enable = true;
      package = pkgs.skhd;

      skhdConfig = ''
        alt - return : open -na "WezTerm"
        alt - w : open -a "Arc"
      '';
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
    home.wezterm.enable = true;

    # Programs
    programs.git.enable = true;
    programs.git.credentialHelper = "osxkeychain";
    programs.git.signingKey = "874E22DF2F9DFCB5";
    programs.draconisplusplus.enable = true;
  };
}
