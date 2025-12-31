{delib, ...}:
delib.module {
  name = "programs.rmpc";

  options.programs.rmpc = with delib; {
    enable = boolOption false;
    address = strOption "127.0.0.1:6600";
  };

  home.ifEnabled = {myconfig, ...}: {
    programs.rmpc = {
      enable = true;
      config = ''
        (
            address: "${myconfig.programs.rmpc.address}",
        )
      '';
    };
  };
}
