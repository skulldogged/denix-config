{
  delib,
  ...
}:
delib.module {
  name = "system.chaotic";

  options.system.chaotic = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    # Chaotic modules are imported via host configuration
  };
}
