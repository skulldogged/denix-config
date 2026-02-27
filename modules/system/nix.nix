{
  delib,
  inputs,
  lib,
  ...
}:
delib.module {
  name = "system.nix";

  options.system.nix = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    nix = {
      daemonCPUSchedPolicy = "batch";
      daemonIOSchedClass = "idle";
      daemonIOSchedPriority = 7;

      gc = {
        automatic = true;
        dates = "Sat *-*-* 03:00";
        options = "--delete-older-than 30d";
      };

      optimise = {
        automatic = true;
        dates = ["04:00"];
      };

      settings = {
        auto-optimise-store = true;
        builders-use-substitutes = true;
        flake-registry = "/etc/nix/registry.json";
        keep-going = true;
        log-lines = 30;
        max-jobs = "auto";
        max-free = "${toString (10 * 1024 * 1024 * 1024)}";
        min-free = "${toString (5 * 1024 * 1024 * 1024)}";
        sandbox-fallback = false;
        sandbox = true;
        use-cgroups = true;
        use-xdg-base-directories = true;
        warn-dirty = false;

        system-features = [
          "nixos-test"
          "kvm"
          "recursive-nix"
          "big-parallel"
          "gccarch-x86-64-v4"
        ];

        allowed-users = [
          "root"
          "@wheel"
          "nix-builder"
        ];

        trusted-users = [
          "root"
          "@wheel"
          "nix-builder"
        ];

        extra-experimental-features = [
          "flakes"
          "nix-command"
          "recursive-nix"
          "ca-derivations"
          "auto-allocate-uids"
          "cgroups"
        ];

        substituters = [
          "https://cache.skulldogged.dev/nix"
          "https://hyprland.cachix.org/"
          "https://nix-community.cachix.org/"
          "https://pupbrained.cachix.org/"
        ];

        trusted-public-keys = [
          "nix:q+5/YijBjROGkRPi6Kg2e2pPYj24/9oHNyc1HSlZ8AM="
          "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "pupbrained.cachix.org-1:C64g/tdHk/o5bl9AZYW1a7XFRXhxa4XaufpIOxMsgxU="
        ];
      };
    };
  };

  darwin.ifEnabled = {
    nix = {
      optimise.automatic = true;
      gc = {
        automatic = true;
        interval.Day = 7;
      };

      daemonIOLowPriority = true;
      daemonProcessType = "Adaptive";
      distributedBuilds = true;
      nixPath = ["nixpkgs=${inputs.nixpkgs}"];
      registry = lib.mapAttrs (_: v: {flake = v;}) inputs;

      settings = {
        builders-use-substitutes = true;
        extra-experimental-features = "nix-command flakes";
        flake-registry = "/etc/nix/registry.json";
        keep-derivations = true;
        keep-outputs = true;
        max-jobs = "auto";
        warn-dirty = false;
        extra-sandbox-paths = ["/nix/var/cache/ccache"];

        substituters = [
          "https://cache.skulldogged.dev/nix"
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ];

        trusted-substituters = [
          "cache.skulldogged.dev"
          "cache.nixos.org"
          "nix-community.cachix.org"
        ];

        trusted-public-keys = [
          "nix:q+5/YijBjROGkRPi6Kg2e2pPYj24/9oHNyc1HSlZ8AM="
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
        ];

        trusted-users = ["marshall"];
      };
    };
  };
}
