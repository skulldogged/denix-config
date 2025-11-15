{
  delib,
  ...
}:
delib.module {
  name = "system.security";

  options.system.security = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    security = {
      rtkit.enable = true;

      pam = {
        services.login.enableGnomeKeyring = true;

        loginLimits = [
          {
            domain = "*";
            item = "nofile";
            type = "-";
            value = "32768";
          }
          {
            domain = "*";
            item = "memlock";
            type = "-";
            value = "32768";
          }
        ];
      };

      sudo-rs = {
        enable = true;
        wheelNeedsPassword = false;
        execWheelOnly = true;
      };

      tpm2 = {
        enable = true;
        pkcs11.enable = true;
        tctiEnvironment.enable = true;
      };
    };
  };
}
