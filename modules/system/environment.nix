{
  delib,
  inputs,
  pkgs,
  lib,
  ...
}:
delib.module {
  name = "system.environment";

  options.system.environment = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {myconfig, ...}: let
    nautilusMyComputer =
      inputs.nautilus-my-computer.packages.${pkgs.stdenv.hostPlatform.system}.default;
    pythonModulePath = package: "${package}/${pkgs.python3.sitePackages}";
    pygobjectPath = pythonModulePath pkgs.python3Packages.pygobject3;
    pycairoPath = pythonModulePath pkgs.python3Packages.pycairo;
    nautilusPython = pkgs.nautilus-python.overrideAttrs (old: {
      buildInputs = (old.buildInputs or []) ++ [pkgs.python3Packages.pycairo];
      postPatch =
        (old.postPatch or "")
        + ''
          substituteInPlace src/nautilus-python.c \
            --replace-fail "'${pygobjectPath}'" "'${pygobjectPath}', '${pycairoPath}'"
        '';
    });
    nautilusWithMyComputer = pkgs.nautilus.overrideAttrs (old: {
      # Keep extension discovery local to Nautilus so terminal, desktop, and
      # D-Bus launches all work without requiring a fresh login environment.
      preFixup =
        (old.preFixup or "")
        + ''
          gappsWrapperArgs+=(
            --set NAUTILUS_4_EXTENSION_DIR "${nautilusPython}/lib/nautilus/extensions-4"
            --prefix XDG_DATA_DIRS : "${nautilusMyComputer}/share"
          )
        '';
    });
  in {
    environment = {
      localBinInPath = true;

      sessionVariables =
        {
          DIRENV_WARN_TIMEOUT = "100s";
          EDITOR = "nvim";
        }
        // lib.optionalAttrs myconfig.host.isDesktop {
          BROWSER = "helium";
          NIXOS_OZONE_WL = "1";
          TERMINAL = "wezterm";
        };

      systemPackages = with pkgs;
        [
          sops
          libsecret
          man-pages
          man-pages-posix
          nixd
          pciutils
        ]
        ++ lib.optionals myconfig.host.isDesktop [
          jamesdsp
          nautilusWithMyComputer
          nautilusPython
          nautilusMyComputer
          papirus-icon-theme
          python313
          sound-theme-freedesktop
          tpm2-tss
          uutils-coreutils-noprefix
          xclip
        ];
    };

    systemd.user.settings.Manager.DefaultEnvironment = "PATH=${lib.concatStringsSep ":" [
      "/run/wrappers/bin"
      "/etc/profiles/per-user/%u/bin"
      "/nix/var/nix/profiles/default/bin"
      "/run/current-system/sw/bin"
    ]}";

    time = {
      hardwareClockInLocalTime = myconfig.host.isDesktop;
      timeZone = "America/New_York";
    };

    documentation = {
      enable = true;
      doc.enable = true;
      dev.enable = true;
      man.enable = true;
      man.cache.enable = true;
    };

    xdg.mime = lib.mkIf myconfig.host.isDesktop {
      addedAssociations."x-scheme-handler/t3code" = "t3code.desktop";
      defaultApplications."x-scheme-handler/t3code" = "t3code.desktop";
    };
  };
}
