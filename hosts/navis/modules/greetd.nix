{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "navis";

  nixos.ifEnabled = {
    services.greetd = {
      enable = true;
      settings = rec {
        initial_session = {
          command = "${inputs.hyprland.packages.x86_64-linux.hyprland}/bin/start-hyprland";
          user = "marshall";
        };
        default_session = initial_session;
      };
    };
  };
}
