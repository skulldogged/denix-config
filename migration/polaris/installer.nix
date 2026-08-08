# Guarded NixOS installation medium for the verified Polaris hardware.
{
  inputs,
  lib,
  modulesPath,
  pkgs,
  ...
}: let
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2vmQG3o3yMTXUbHYM7evCpUo/V+gK8Lofajt/hEjrB navis"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFve6rzQTu+icju0GGhuyVJ9QenCRHzRgjhyX5iNuinz"
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLNLzoJDzuVhWZXuUO70Yj6bWg6t8kBFH0fWZIIwTC1w9w7Uv0ERuSBcp752fOpkm7fY5c2lyt12/ymEOParbhk= navis-tpm-polaris"
  ];

  openOldData = pkgs.writeShellApplication {
    name = "polaris-open-old-data";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      lvm2
      qemu
      systemd
      util-linux
    ];
    text = builtins.readFile ./open-old-data.sh;
  };

  installBootstrap = pkgs.writeShellApplication {
    name = "polaris-install-bootstrap";
    runtimeInputs = with pkgs; [
      coreutils
      dosfstools
      e2fsprogs
      findutils
      gnugrep
      gnused
      gptfdisk
      jq
      lvm2
      nixos-install-tools
      openOldData
      openssh
      parted
      qemu
      rsync
      systemd
      util-linux
    ];
    text = builtins.readFile ./install-bootstrap.sh;
  };
in {
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  system.stateVersion = "23.11";

  # iso-image.nix passes baseName—not fileName—to the ISO builder.
  image.baseName = lib.mkForce "polaris-migration";

  # The migration procedure only reads LVM/ext4 disks. Never import an
  # unrelated ZFS root pool merely because one is visible to the installer.
  boot.zfs.forceImportRoot = false;

  networking.hostName = "polaris-installer";

  services.openssh = {
    enable = true;
    settings = {
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;

  # The installation-device profile enables sudo while the current sudo-rs
  # module disables it at the same priority. Pin the conventional installer
  # choice explicitly until nixpkgs resolves that profile conflict.
  security = {
    sudo.enable = lib.mkForce true;
    sudo-rs.enable = lib.mkForce false;
  };

  environment = {
    etc."polaris-migration/nix-config".source = inputs.self.outPath;

    systemPackages = [
      installBootstrap
      openOldData
      pkgs.ethtool
      pkgs.git
      pkgs.jq
      pkgs.lvm2
      pkgs.pciutils
      pkgs.qemu
      pkgs.rsync
      pkgs.tmux
      pkgs.usbutils
    ];
  };
}
