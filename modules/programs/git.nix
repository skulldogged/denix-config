{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "programs.git";

  options.programs.git = with delib; {
    enable = boolOption false;
    credentialHelper = allowNull (strOption null);
    signingKey = allowNull (strOption null);
  };

  home.ifEnabled = {myconfig, ...}: {
    programs = {
      delta.enable = true;

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
