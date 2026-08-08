# Minimal first-boot system used only during the storage migration.
{
  inputs,
  lib,
  pkgs,
  ...
}: let
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2vmQG3o3yMTXUbHYM7evCpUo/V+gK8Lofajt/hEjrB navis"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFve6rzQTu+icju0GGhuyVJ9QenCRHzRgjhyX5iNuinz"
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLNLzoJDzuVhWZXuUO70Yj6bWg6t8kBFH0fWZIIwTC1w9w7Uv0ERuSBcp752fOpkm7fY5c2lyt12/ymEOParbhk= navis-tpm-polaris"
  ];
in {
  system.stateVersion = "23.11";

  nix.settings.experimental-features = [
    "flakes"
    "nix-command"
  ];

  boot = {
    initrd.availableKernelModules = [
      "nvme"
      "sd_mod"
      "uas"
      "usb_storage"
      "xhci_pci"
    ];

    kernelModules = [
      "e1000e"
      "i915"
      "kvm-intel"
    ];

    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      timeout = 5;
    };
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_ROOT";
      fsType = "ext4";
    };

    "/boot" = {
      device = "/dev/disk/by-label/NIXOS_BOOT";
      fsType = "vfat";
      options = [
        "dmask=0022"
        "fmask=0022"
      ];
    };
  };

  hardware = {
    cpu.intel.updateMicrocode = true;
    enableRedistributableFirmware = true;
    graphics = {
      enable = true;
      extraPackages = [pkgs.intel-media-driver];
    };
  };

  networking = {
    hostName = "polaris";
    useDHCP = lib.mkForce true;
    networkmanager.enable = true;
    firewall.allowedTCPPorts = [22];
  };

  services.openssh = {
    enable = true;
    settings = {
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users = {
    mutableUsers = false;

    users = {
      root.openssh.authorizedKeys.keys = authorizedKeys;

      marshall = {
        uid = 1000;
        isNormalUser = true;
        extraGroups = [
          "networkmanager"
          "wheel"
        ];
        openssh.authorizedKeys.keys = authorizedKeys;
      };
    };
  };

  # This is intentionally temporary. It permits recovery work over SSH before
  # the normal SOPS-backed user configuration is activated.
  security.sudo.wheelNeedsPassword = false;

  environment = {
    etc."polaris-migration/nix-config".source = inputs.self.outPath;

    systemPackages = with pkgs; [
      curl
      ethtool
      git
      gptfdisk
      jq
      lvm2
      parted
      pciutils
      qemu
      rsync
      tmux
      usbutils
    ];
  };
}
