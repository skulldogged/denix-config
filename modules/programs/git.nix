{
  delib,
  inputs,
  pkgs,
  ...
}: let
  difftasticPackage = pkgs.rustPlatform.buildRustPackage {
    pname = "difftastic";
    version = "0.68.0";

    src = inputs.difftastic-src;
    cargoHash = "sha256-sJv1y1vs5XhixOMgEf9qchMFhKsJXErdWQN91BPMO7s=";

    env = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isStatic {
      RUSTFLAGS = "-C relocation-model=static";
    };

    checkFlags = ["--skip=options::tests::test_detect_display_width"];

    nativeInstallCheckInputs = [pkgs.versionCheckHook];
    versionCheckProgram = "${placeholder "out"}/bin/difft";
    versionCheckProgramArg = "--version";
    doInstallCheck = true;

    meta = pkgs.difftastic.meta;
  };

  nixGithubAccessToken = pkgs.writeShellApplication {
    name = "nix-github-access-token";
    runtimeInputs = with pkgs; [
      coreutils
      gh
    ];
    text = ''
      config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/nix"
      gh_config="''${GH_CONFIG_DIR:-''${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
      token_path="$config_dir/access-tokens.conf"

      mkdir -p "$config_dir"
      chmod 0700 "$config_dir"

      if [[ ! -s "$gh_config" ]]; then
        rm -f "$token_path"
        exit 0
      fi

      if ! token="$(gh auth token --hostname github.com 2>/dev/null)"; then
        echo "Unable to read the active GitHub token; preserving the existing Nix token file" >&2
        exit 1
      fi
      if [[ -z "$token" || "$token" =~ [[:space:]] ]]; then
        echo "GitHub CLI returned an invalid token" >&2
        exit 1
      fi

      temp_path="$(mktemp "$config_dir/.access-tokens.conf.XXXXXX")"
      trap 'rm -f "$temp_path"' EXIT
      printf 'access-tokens = github.com=%s\n' "$token" > "$temp_path"
      chmod 0600 "$temp_path"

      if [[ ! -e "$token_path" ]] || ! cmp -s "$temp_path" "$token_path"; then
        mv -f "$temp_path" "$token_path"
      fi
    '';
  };
in
  delib.module {
    name = "programs.git";

    options.programs.git = with delib; {
      enable = boolOption false;
      credentialHelper = allowNull (strOption null);
      signingKey = allowNull (strOption null);
    };

    home.ifEnabled = {myconfig, ...}:
      pkgs.lib.mkMerge [
        {
          programs = {
            difftastic = {
              enable = true;
              git.enable = true;
              package = difftasticPackage;
            };

            git = {
              enable = true;
              lfs.enable = true;

              signing = {
                signByDefault = true;
                key = myconfig.programs.git.signingKey;
              };

              settings = {
                user = {
                  name = myconfig.constants.userfullname;
                  email = myconfig.constants.useremail;
                };

                credential.helper = myconfig.programs.git.credentialHelper;

                init.defaultBranch = "main";
                push.autoSetupRemote = true;
              };
            };

            gh = {
              enable = true;
              extensions = with pkgs; [
                gh-dash
                gh-markdown-preview
                gh-notify
              ];
            };
          };
        }

        (pkgs.lib.mkIf pkgs.stdenv.isLinux {
          # Keep the public Nix configuration in the store while loading the
          # GitHub credential from a private, runtime-generated sibling file.
          xdg.configFile."nix/nix.conf".text = ''
            !include access-tokens.conf
          '';

          systemd.user.services.nix-github-access-token = {
            Unit.Description = "Refresh Nix's GitHub access token";

            Service = {
              Type = "oneshot";
              ExecStart = "${nixGithubAccessToken}/bin/nix-github-access-token";
              UMask = "0077";
              NoNewPrivileges = true;
              PrivateTmp = true;
            };

            Install.WantedBy = ["default.target"];
          };

          systemd.user.paths.nix-github-access-token = {
            Unit.Description = "Watch GitHub CLI credentials for Nix";
            Path.PathChanged = "%h/.config/gh/hosts.yml";
            Install.WantedBy = ["default.target"];
          };
        })
      ];
  }
