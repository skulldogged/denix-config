{
  config,
  delib,
  inputs,
  pkgs,
  ...
}: let
  username = config.myconfig.constants.username;
  user = config.users.users.${username};
  system = pkgs.stdenv.hostPlatform.system;
  codex = inputs.codex-cli-nix.packages.${system}.codex;
  t3code = inputs.t3code-flake.packages.${system}.t3-code-nightly;
  t3 = pkgs.writeShellScriptBin "t3" ''
    exec ${pkgs.nodejs_24}/bin/node \
      ${t3code}/libexec/t3-code-nightly/resources/app.asar.unpacked/apps/server/dist/bin.mjs \
      "$@"
  '';
in
  delib.module {
    name = "polaris";

    nixos.ifEnabled = {
      environment.systemPackages = [t3];

      services.tailscale.extraSetFlags = ["--operator=${username}"];

      systemd.services.t3-code = {
        description = "T3 Code remote server";
        wantedBy = ["multi-user.target"];
        after = [
          "network-online.target"
          "tailscaled.service"
          "tailscaled-set.service"
        ];
        wants = ["network-online.target"];
        requires = ["tailscaled.service"];

        environment = {
          HOME = user.home;
          T3CODE_HOME = "${user.home}/.t3";
        };

        path = [
          codex
          pkgs.claude-code
          pkgs.gh
          pkgs.git
          pkgs.opencode
          pkgs.tailscale
        ];

        serviceConfig = {
          User = username;
          Group = user.group;
          ExecStart = "${t3}/bin/t3 serve --tailscale-serve";
          WorkingDirectory = user.home;
          Restart = "on-failure";
          RestartSec = 5;
          UMask = "0077";
        };
      };
    };
  }
