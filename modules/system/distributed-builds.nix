{delib, ...}: let
  mkBuildMachines = cfg: [
    {
      inherit (cfg) hostName sshUser sshKey publicHostKey systems maxJobs speedFactor supportedFeatures;
      protocol = "ssh-ng";
    }
  ];
in
  delib.module {
    name = "system.distributed-builds";

    options.system.distributed-builds = with delib; {
      enable = boolOption false;
      hostName = strOption "";
      sshUser = strOption "nix-builder";
      sshKey = strOption "";
      publicHostKey = strOption "";
      systems = listOfOption str ["x86_64-linux"];
      maxJobs = intOption 8;
      speedFactor = intOption 10;
      supportedFeatures = listOfOption str [
        "nixos-test"
        "kvm"
        "recursive-nix"
        "big-parallel"
        "gccarch-x86-64-v4"
      ];
    };

    nixos.ifEnabled = {myconfig, ...}: {
      nix = {
        distributedBuilds = true;
        buildMachines = mkBuildMachines myconfig.system.distributed-builds;
      };
    };

    darwin.ifEnabled = {myconfig, ...}: {
      nix.buildMachines = mkBuildMachines myconfig.system.distributed-builds;
    };
  }
