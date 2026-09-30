{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "programs.trmnl-fleet";

  options.programs.trmnl-fleet = with delib; {
    enable = boolOption false;
  };

  # Pushes fleet health to the TRMNL display every 10 minutes. The webhook URL
  # is read from ~/.config/trmnl-fleet/webhook, outside the store.
  home.ifEnabled = {
    imports = [inputs.trmnl-fleet.homeModules.default];

    services.trmnl-fleet.enable = true;
  };
}
