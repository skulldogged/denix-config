{
  delib,
  inputs,
  pkgs,
  ...
}: let
  gtk3CatppuccinCss = ''
    /* Catppuccin Mocha colours over GTK 3's native Adwaita layout. */
    @define-color theme_bg_color #1e1e2e;
    @define-color theme_fg_color #cdd6f4;
    @define-color theme_base_color #181825;
    @define-color theme_text_color #cdd6f4;

    @define-color theme_selected_bg_color #a6e3a1;
    @define-color theme_selected_fg_color #11111b;

    @define-color insensitive_bg_color #313244;
    @define-color insensitive_fg_color #7f849c;
    @define-color insensitive_base_color #181825;

    @define-color theme_unfocused_bg_color #1e1e2e;
    @define-color theme_unfocused_fg_color #a6adc8;
    @define-color theme_unfocused_base_color #181825;
    @define-color theme_unfocused_text_color #bac2de;
    @define-color theme_unfocused_selected_bg_color #a6e3a1;
    @define-color theme_unfocused_selected_fg_color #11111b;

    @define-color borders #45475a;
    @define-color unfocused_borders #313244;

    @define-color warning_color #f9e2af;
    @define-color error_color #f38ba8;
    @define-color success_color #a6e3a1;

    @define-color content_view_bg #181825;
    @define-color text_view_bg #11111b;
  '';

  gtk4CatppuccinCss = ''
    /*
     * Catppuccin Mocha colours over GTK 4/libadwaita's native layout.
     * Only semantic colours are changed; widget geometry remains Adwaita.
     */
    @define-color window_bg_color #1e1e2e;
    @define-color window_fg_color #cdd6f4;

    @define-color view_bg_color #1e1e2e;
    @define-color view_fg_color #cdd6f4;

    @define-color headerbar_bg_color #313244;
    @define-color headerbar_fg_color #cdd6f4;
    @define-color headerbar_border_color #45475a;
    @define-color headerbar_backdrop_color #1e1e2e;
    @define-color headerbar_shade_color rgba(17, 17, 27, 0.55);
    @define-color headerbar_darker_shade_color rgba(17, 17, 27, 0.9);

    @define-color sidebar_bg_color #181825;
    @define-color sidebar_fg_color #cdd6f4;
    @define-color sidebar_backdrop_color #1e1e2e;
    @define-color sidebar_shade_color rgba(17, 17, 27, 0.35);
    @define-color sidebar_border_color #45475a;

    @define-color secondary_sidebar_bg_color #1e1e2e;
    @define-color secondary_sidebar_fg_color #cdd6f4;
    @define-color secondary_sidebar_backdrop_color #181825;
    @define-color secondary_sidebar_shade_color rgba(17, 17, 27, 0.35);
    @define-color secondary_sidebar_border_color #313244;

    @define-color card_bg_color rgba(205, 214, 244, 0.08);
    @define-color card_fg_color #cdd6f4;
    @define-color card_shade_color rgba(17, 17, 27, 0.45);

    @define-color dialog_bg_color #313244;
    @define-color dialog_fg_color #cdd6f4;
    @define-color popover_bg_color #313244;
    @define-color popover_fg_color #cdd6f4;
    @define-color popover_shade_color rgba(17, 17, 27, 0.45);

    @define-color thumbnail_bg_color #45475a;
    @define-color thumbnail_fg_color #cdd6f4;
    @define-color shade_color rgba(17, 17, 27, 0.35);
    @define-color scrollbar_outline_color rgba(17, 17, 27, 0.95);

    @define-color accent_bg_color #a6e3a1;
    @define-color accent_fg_color #11111b;
    @define-color accent_color #a6e3a1;
    @define-color destructive_bg_color #f38ba8;
    @define-color destructive_fg_color #11111b;
    @define-color destructive_color #f38ba8;
    @define-color success_bg_color #a6e3a1;
    @define-color success_fg_color #11111b;
    @define-color success_color #a6e3a1;
    @define-color warning_bg_color #f9e2af;
    @define-color warning_fg_color #11111b;
    @define-color warning_color #f9e2af;
    @define-color error_bg_color #f38ba8;
    @define-color error_fg_color #11111b;
    @define-color error_color #f38ba8;

    :root {
      --accent-bg-color: #a6e3a1;
      --accent-fg-color: #11111b;
      --accent-color: #a6e3a1;
    }
  '';
in
  delib.rice {
    name = "catppuccin-mocha";

    nixos = {
      imports = [inputs.catppuccin.nixosModules.catppuccin];

      catppuccin = {
        autoEnable = true;
        enable = true;
        cache.enable = true;
        flavor = "mocha";
        accent = "green";
      };
    };

    home = {
      imports = [
        inputs.catppuccin.homeModules.catppuccin
        inputs.nix-colors.homeManagerModules.default
      ];

      catppuccin = {
        autoEnable = true;
        enable = true;
        flavor = "mocha";
        accent = "green";
        cursors.enable = true;
        gtk.icon.enable = false;
        kvantum.enable = false;
      };

      colorScheme = inputs.nix-colors.colorSchemes.catppuccin-mocha;

      home.pointerCursor.enable = true;

      gtk = {
        enable = true;
        colorScheme = "dark";
        theme = {
          name = "Adwaita";
          package = null;
        };
        iconTheme = {
          name = "kora";
          package = pkgs.kora-icon-theme;
        };

        # GTK 4/libadwaita uses its native styling and reads dark mode from
        # the desktop preference written by the GTK 3 configuration.
        gtk3 = {
          extraConfig."gtk-decoration-layout" = ":";
          extraCss = gtk3CatppuccinCss;
        };

        gtk4 = {
          colorScheme = null;
          extraConfig."gtk-decoration-layout" = ":";
          extraCss = gtk4CatppuccinCss;
          theme = null;
        };
      };

      dconf.settings."org/gnome/desktop/interface"."accent-color" = "green";
      dconf.settings."org/gnome/desktop/wm/preferences"."button-layout" = ":";

      qt = {
        enable = true;
        platformTheme.name = "kde";
      };

      xdg.enable = true;
    };
  }
