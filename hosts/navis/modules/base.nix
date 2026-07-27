{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "navis";

  options.navis = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    facter.reportPath = ../facter.json;

    networking = {
      hosts."37.27.111.236" = ["builder"];
      networkmanager.wifi.powersave = false;
    };

    environment = {
      systemPackages = [
        pkgs.sbctl
        pkgs.ssh-tpm-agent
      ];
      sessionVariables.AQ_DRM_DEVICES = "/dev/dri/card1";
    };

    programs.ssh = {
      startAgent = pkgs.lib.mkForce true;

      extraConfig = ''
        Host polaris
          ForwardAgent yes
          IdentityAgent ''${XDG_RUNTIME_DIR}/ssh-tpm-agent.sock
      '';
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
        wants = ["ssh-agent.service"];
        after = ["ssh-agent.service"];

        serviceConfig = {
          Environment = "SSH_TPM_AUTH_SOCK=%t/ssh-tpm-agent.sock";
          ExecStart = "${pkgs.ssh-tpm-agent}/bin/ssh-tpm-agent -A %t/ssh-agent";
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

      tailscale = {
        enable = true;
        openFirewall = true;
      };

      xserver.videoDrivers = ["nvidia"];
    };
  };
}
