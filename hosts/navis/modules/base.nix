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

  nixos.ifEnabled = let
    polarisSshProxy = pkgs.writeShellScript "ssh-polaris-proxy" ''
      if ${lib.getExe pkgs.netcat-openbsd} -z -w 2 100.92.239.38 "$1" >/dev/null 2>&1; then
        exec ${lib.getExe pkgs.netcat-openbsd} 100.92.239.38 "$1"
      fi

      exec ${lib.getExe pkgs.netcat-openbsd} 192.168.1.82 "$1"
    '';
  in {
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
          # Prefer Polaris over Tailscale, then fall back to its LAN address.
          # HostName stays unset so known_hosts continues to use `polaris`.
          Host polaris
            User marshall
            ForwardAgent yes
            IdentitiesOnly yes
            IdentityFile ~/.ssh/id_ecdsa_polaris_tpm.pub
            IdentityAgent /run/user/%i/ssh-tpm-agent.sock
            ProxyCommand ${polarisSshProxy} %p

          # "builder" resolves via /etc/hosts (networking.hosts above). Keep
          # HostName unset so manual SSH continues to use the literal alias.
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
    };

    programs.solaar.enable = true;

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
        extraSetFlags = ["--exit-node-allow-lan-access=true"];
        openFirewall = true;
      };

      xserver.videoDrivers = ["nvidia"];
    };
  };
}
