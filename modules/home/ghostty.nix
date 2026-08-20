{
  delib,
  lib,
  pkgs,
  ...
}: let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
  delib.module {
    name = "home.ghostty";

    options.home.ghostty = with delib; {
      enable = boolOption false;
    };

    home.ifEnabled = _: {
      programs.ghostty = {
        enable = true;

        # nixpkgs' Ghostty package is Linux-only. On macOS, nix-darwin installs
        # the official Homebrew cask while Home Manager still owns this config.
        package =
          if isDarwin
          then null
          else pkgs.ghostty;

        # Herdr owns panes and tabs on Linux. Clearing Ghostty's defaults keeps
        # shortcuts such as Ctrl+Shift+N available to Herdr.
        clearDefaultKeybinds = !isDarwin;

        settings =
          {
            theme = lib.mkDefault "Catppuccin Mocha";
            font-family =
              ["Maple Mono NF"]
              ++ lib.optionals (!isDarwin) [
                "Symbols Nerd Font Mono"
                "Twitter Color Emoji"
              ];
            font-size =
              if isDarwin
              then 14
              else 10;

            cursor-style = "bar";
            cursor-style-blink = true;

            background-opacity =
              if isDarwin
              then 0.85
              else 0.8;
            background-blur =
              if isDarwin
              then 32
              else false;

            scrollbar = "never";
            window-padding-x = 0;
            window-padding-y = 0;
            confirm-close-surface = false;
            copy-on-select = false;
            resize-overlay = "never";
          }
          // lib.optionalAttrs isDarwin {
            # Keep the native resizable frame without a titlebar.
            macos-titlebar-style = "hidden";
            window-decoration = "auto";
          }
          // lib.optionalAttrs (!isDarwin) {
            command = "herdr";
            window-decoration = "none";
            window-show-tab-bar = "never";
            keybind = [
              "ctrl+shift+c=copy_to_clipboard"
              "ctrl+shift+v=paste_from_clipboard"
              "ctrl+shift+f=start_search"
              "ctrl+shift+equal=increase_font_size:1"
              "ctrl+shift+minus=decrease_font_size:1"
              "ctrl+shift+zero=reset_font_size"
              "ctrl+shift+r=reload_config"
              "ctrl+alt+shift+t=new_window"
            ];
          };
      };
    };
  }
