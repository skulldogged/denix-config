{
  delib,
  lib,
  pkgs,
  ...
}: let
  account = "skullbotted";
  accountEmail = "319073449+skullbotted@users.noreply.github.com";
  secretFile = ../../secrets/agent-github.yaml;

  agentGithub =
    pkgs.runCommandLocal "agent-github-machine-user" {
      nativeBuildInputs = [pkgs.makeWrapper];
    } ''
      mkdir -p "$out/bin"
      install -m755 ${../../files/agent-github/agent-gh} "$out/bin/agent-gh"
      install -m755 ${../../files/agent-github/agent-git} "$out/bin/agent-git"
      install -m755 ${../../files/agent-github/token-store} "$out/bin/token-store"
      patchShebangs "$out/bin"

      runtime_path=${lib.makeBinPath (with pkgs; [
        coreutils
        gh
        git
        gnugrep
        gnused
        libsecret
        openssh
      ])}
      for program in agent-gh agent-git token-store; do
        wrapProgram "$out/bin/$program" --prefix PATH : "$runtime_path"
      done
    '';
in
  delib.module {
    name = "programs.agent-github";

    options.programs.agent-github = with delib; {
      enable = boolOption false;
      repositories = listOption [
        "skulldogged/denix-config"
        "skulldogged/gpui-ghostty-agent-terminal"
      ];
    };

    nixos.ifEnabled = {myconfig, ...}: let
      inherit (myconfig.constants) username;
      commonSecret = {
        sopsFile = secretFile;
        owner = username;
        group = "users";
        mode = "0400";
      };
    in {
      sops.secrets = {
        agent-github-token = commonSecret // {key = "github_token";};
        agent-github-auth-key = commonSecret // {key = "github_auth_key";};
        agent-github-signing-key = commonSecret // {key = "github_signing_key";};
      };
    };

    home.ifEnabled = {myconfig, ...}: let
      repositories = lib.sort builtins.lessThan (lib.unique myconfig.programs.agent-github.repositories);
      repositoryRegistry = pkgs.writeText "agent-github-repositories" (
        lib.concatStringsSep "\n" repositories + "\n"
      );
    in {
      assertions = [
        {
          assertion = lib.all (repository: builtins.match "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+" repository != null) repositories;
          message = "programs.agent-github.repositories must contain OWNER/REPOSITORY names";
        }
      ];

      home.packages = [agentGithub];

      xdg.configFile."codex-github-machine/setup.env" = {
        force = true;
        text = ''
          AGENT_GITHUB_USER=${account}
          AGENT_GITHUB_EMAIL=${accountEmail}
          AGENT_GITHUB_AUTH_KEY=/run/secrets/agent-github-auth-key
          AGENT_GITHUB_SIGNING_KEY=/run/secrets/agent-github-signing-key
          AGENT_GITHUB_TOKEN_FILE=/run/secrets/agent-github-token
          AGENT_GITHUB_REPOSITORIES_FILE=${repositoryRegistry}
        '';
      };

      home.file.".codex/AGENTS.md" = {
        force = true;
        source = ../../files/agent-github/AGENTS.md;
      };
    };
  }
