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
in
  delib.module {
    name = "programs.git";

    options.programs.git = with delib; {
      enable = boolOption false;
      credentialHelper = allowNull (strOption null);
      signingKey = allowNull (strOption null);
    };

    home.ifEnabled = {myconfig, ...}: {
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
    };
  }
