{
  delib,
  ...
}:
delib.module {
  name = "programs.rmpc";

  options.programs.rmpc = with delib; {
    enable = boolOption false;
    address = strOption "192.168.1.82:6600";
  };

  home.ifEnabled = {myconfig, ...}: {
    programs.rmpc = {
      enable = true;
      config = ''
        Config(
            address: "${myconfig.programs.rmpc.address}",
        )
      '';
    };
  };
}
