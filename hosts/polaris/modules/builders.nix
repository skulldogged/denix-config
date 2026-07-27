{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    nix = {
      distributedBuilds = true;

      buildMachines = [
        {
          hostName = "builder";
          protocol = "ssh-ng";
          sshUser = "nix-builder";
          sshKey = "/home/marshall/.ssh/nix-builder_ed25519";
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUVlOHJ0eTl4L0sxS1kvU2srOHQyQ1FTeE41amVLa3p0SW9USUt6dG5OSHogcm9vdEBidWlsZGVyCg==";
          systems = ["x86_64-linux"];
          maxJobs = 8;
          speedFactor = 20;
          supportedFeatures = [
            "benchmark"
            "big-parallel"
            "gccarch-x86-64-v4"
            "kvm"
            "nixos-test"
            "recursive-nix"
          ];
        }
      ];

      nixPath = ["nixpkgs=${inputs.nixpkgs}"];
      registry.nixpkgs.flake = inputs.nixpkgs;
    };

    programs.ssh.knownHosts.builder.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEe8rty9x/K1KY/Sk+8t2CQSxN5jeKkztIoTIKztnNHz";

    networking.hosts."37.27.111.236" = ["builder"];
  };
}
