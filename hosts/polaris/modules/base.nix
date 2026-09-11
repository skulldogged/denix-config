{
  config,
  delib,
  inputs,
  lib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  options.polaris = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = let
    androidSdkBase =
      ((pkgs.androidenv.override {licenseAccepted = true;}).composeAndroidPackages {
        platformVersions = ["37.0"];
        buildToolsVersions = ["36.0.0"];
        includeEmulator = true;
        includeSystemImages = true;
        systemImageTypes = ["google_apis"];
        abiVersions = ["x86_64"];
        includeCmake = false;
        includeNDK = false;
      }).androidsdk;
    # T3 checks the conventional latest path; Nix uses a versioned directory.
    androidSdk = pkgs.symlinkJoin {
      name = "android-sdk-t3";
      paths = [androidSdkBase];
      postBuild = ''
        for tools in "$out/libexec/android-sdk/cmdline-tools/"*; do
          if [ -x "$tools/bin/avdmanager" ]; then
            ln -s "$tools" "$out/libexec/android-sdk/cmdline-tools/latest"
            break
          fi
        done
        test -x "$out/libexec/android-sdk/cmdline-tools/latest/bin/avdmanager"
      '';
    };
    androidHome = "${androidSdk}/libexec/android-sdk";
    bridge = pkgs.writeShellScriptBin "proton-bridge-headless" (
      lib.replaceStrings
      ["$state/pass-package/bin:/run/current-system/sw/bin:$PATH"]
      ["${lib.makeBinPath [pkgs.pass pkgs.gnupg pkgs.protonmail-bridge pkgs.systemd pkgs.coreutils]}:$PATH"]
      (builtins.readFile ./services/proton-bridge-headless.sh)
    );
  in {
    sops = {
      defaultSopsFile = ../../../secrets/polaris.yaml;
      age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    };

    time.timeZone = "America/New_York";

    nix = {
      nixPath = ["nixpkgs=${inputs.nixpkgs}"];
      registry.nixpkgs.flake = inputs.nixpkgs;
      settings.trusted-users = lib.mkForce ["root"];
    };

    users.users.${config.myconfig.constants.username}.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2vmQG3o3yMTXUbHYM7evCpUo/V+gK8Lofajt/hEjrB navis"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFve6rzQTu+icju0GGhuyVJ9QenCRHzRgjhyX5iNuinz"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLNLzoJDzuVhWZXuUO70Yj6bWg6t8kBFH0fWZIIwTC1w9w7Uv0ERuSBcp752fOpkm7fY5c2lyt12/ymEOParbhk= navis-tpm-polaris"
    ];

    environment = {
      systemPackages = with pkgs; [
        androidSdk
        bridge
        bento4
        codeium
        ffmpeg
        ghostty.terminfo
        graalvmPackages.graalvm-oracle_17
        nodejs_24
        opencode
        uv
      ];

      sessionVariables = {
        BROWSER = "helium";
        ANDROID_HOME = androidHome;
        ANDROID_SDK_ROOT = androidHome;
      };
    };

    # T3 is a lingering user service and does not inherit login-shell variables.
    home-manager.users.${config.myconfig.constants.username}.xdg.configFile.
      "systemd/user/t3code.service.d/android.conf".text = ''
      [Service]
      Environment=ANDROID_HOME=${androidHome}
      Environment=ANDROID_SDK_ROOT=${androidHome}
    '';

    services = {
      desktopManager.plasma6.enable = true;
      displayManager.sddm.enable = true;

      eternal-terminal.enable = true;
      protonmail-bridge.enable = true;
    };

    systemd.user.services.protonmail-bridge = {
      after = lib.mkForce [];
      wantedBy = lib.mkForce ["default.target"];
      serviceConfig = {
        ExecStart = lib.mkForce "${bridge}/bin/proton-bridge-headless";
        RestartSec = 15;
        UMask = "0077";
      };
    };

    virtualisation = {
      containers.enable = true;
      docker.enable = false;

      podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };

    programs.mosh = {
      enable = true;
      openFirewall = false;
    };

    security = {
      pam = {
        rssh.enable = true;

        services = {
          gdm.enableGnomeKeyring = true;
          sudo.rssh = true;
          sudo-i.rssh = true;
        };
      };

      sudo-rs.wheelNeedsPassword = lib.mkForce true;

      sudo.extraRules = [
        {
          users = [config.myconfig.constants.username];
          commands = [
            {
              command = "/run/current-system/sw/bin/podman";
              options = ["NOPASSWD"];
            }
          ];
        }
      ];
    };
  };
}
