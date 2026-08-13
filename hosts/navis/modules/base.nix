{
  delib,
  lib,
  pkgs,
  ...
}:
delib.module {
  name = "navis";

  options.navis = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    networking = {
      hosts."37.27.111.236" = ["builder"];

      interfaces = {
        enp5s0.useDHCP = lib.mkDefault true;
        wlp4s0.useDHCP = lib.mkDefault true;
      };

      networkmanager.wifi.powersave = false;
    };

    environment = {
      systemPackages = [
        pkgs.sbctl
        pkgs.ssh-tpm-agent
      ];
      sessionVariables.AQ_DRM_DEVICES = "/dev/dri/nvidia-dgpu";
    };

    programs = {
      moonlight-qt = {
        enable = true;
        capSysNice = true;
      };

      ssh = {
        # Overrides the shared `system.programs` module, which sets
        # `startAgent = host.isServer` (false on this desktop host).
        startAgent = pkgs.lib.mkForce true;

        # IdentityFile points at the public key, not the TPM-sealed `.tpm`
        # blob: ssh-tpm-agent auto-loads ~/.ssh/*.tpm into the agent (see the
        # ssh-tpm-agent units below), so ssh only needs the public half to
        # select the identity. OpenSSH cannot parse a `.tpm` file directly.
        extraConfig = ''
          Host polaris
            HostName 192.168.1.82
            User marshall
            ForwardAgent yes
            IdentitiesOnly yes
            IdentityFile ~/.ssh/id_ecdsa_polaris_tpm.pub
            IdentityAgent /run/user/%i/ssh-tpm-agent.sock

          # "builder" resolves via /etc/hosts (networking.hosts above). Do not
          # set HostName here: nix's remote-builder SSH verifies the host key
          # under the literal name "builder", and a HostName directive would
          # change that lookup to the IP and break build offloading.
          Host builder
            User marshall
            IdentitiesOnly yes
            IdentityFile ~/.ssh/id_hetzner
        '';
      };
    };

    systemd.user = {
      sockets.ssh-tpm-agent = {
        description = "SSH TPM agent socket";
        wantedBy = ["sockets.target"];

        socketConfig = {
          ListenStream = "%t/ssh-tpm-agent.sock";
          SocketMode = "0600";
          Service = "ssh-tpm-agent.service";
        };
      };

      services.ssh-tpm-agent = {
        description = "SSH TPM agent";
        requires = ["ssh-tpm-agent.socket"];

        serviceConfig = {
          Environment = "SSH_TPM_AUTH_SOCK=%t/ssh-tpm-agent.sock";
          ExecStart = "${pkgs.ssh-tpm-agent}/bin/ssh-tpm-agent";
          SuccessExitStatus = 2;
          Type = "simple";
        };
      };
    };

    hardware.logitech.wireless = {
      enable = true;
      enableGraphical = true;
    };

    services = {
      gnome.gcr-ssh-agent.enable = pkgs.lib.mkForce false;
      gvfs.enable = true;

      udev.extraRules = ''
        # AQ_DRM_DEVICES uses ':' as its device separator, so the standard
        # PCI by-path name cannot be passed to Aquamarine directly.
        SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="0000:01:00.0", SYMLINK+="dri/nvidia-dgpu"
      '';

      tailscale = {
        enable = true;
        openFirewall = true;
      };

      xserver.videoDrivers = ["nvidia"];
    };
  };
}
