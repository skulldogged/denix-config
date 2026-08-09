# Polaris bare-metal migration

This file records the verified storage layout and the safe migration order for
replacing XCP-ng with NixOS on the HP EliteDesk 800 G5 Mini.

## Verified hardware and identities

- System: HP EliteDesk 800 G5 Desktop Mini, Q370 chipset, i7-9700T, 64 GiB RAM.
- Ethernet: Intel I219-LM, physical MAC `38:22:e2:0c:1e:5a`.
- Internal install target: 477 GiB KingFast NVMe, currently `/dev/nvme0n1`.
- External data disk: 1.9 TiB SPCC SSD, serial
  `SPCC_Solid_State_Disk_AA000000000000003076`, currently `/dev/sda`.
- XCP-ng external SR UUID: `44ab286b-ed50-8661-bcef-2027159260c3`.
- External SR filesystem UUID: `92ea9196-44a8-427e-a84a-c216be92cf76`.
- Data VHD UUID: `123fb967-bbe7-41eb-a092-664bcff6ad69`.
- Data VHD virtual size: 1.5 TiB; current ext4 usage is approximately 123 GiB.
- Data filesystem UUID inside the VHD:
  `88133d6c-7eed-4b4c-aba3-f561f9ac34f6`.

The data VHD has been verified with `vhd-util` to have no parent. It is a
standalone VHD, not a snapshot chain.

## Hard safety boundaries

1. Do not repartition, format, or install onto the 2 TB SPCC USB SSD while it
   still contains the XCP-ng SR and the only local Music VHD.
2. Install NixOS only onto the 477 GB KingFast NVMe.
3. Do not reformat the external SSD until its VHD contents have been copied to
   the new NVMe installation and the Restic snapshot has been independently
   verified.
4. Before wiping the NVMe, shut down the NixOS VM and copy its root VDI
   (`287f12ba-f4ad-4bf7-92b1-624044302e78`) to the external SR for rollback.
5. Keep the stopped CoreOS VM and migration snapshots until the bare-metal
   system has passed service, reboot, and restore tests.

## Existing backups and bootstrap material

- Encrypted Backblaze B2 Restic repository, checked after each backup.
- Expanded pre-migration snapshot `8f39e4c6`, completed on 2026-08-08 after
  processing 132.214 GiB. The subsequent repository check reported no errors.
- Consistent service staging at `/var/backup/polaris` in Restic.
- CoreOS Vaultwarden stopped-state copy at
  `/mnt/migration-backup/vaultwarden-coreos-final-20260808`.
- Bare-metal bootstrap directory at
  `/mnt/migration-backup/baremetal-bootstrap` after the updated backup job runs.

The bootstrap directory contains the live Nix working tree, the current SSH
host key required to decrypt Polaris SOPS secrets, and temporary AMT/XO
credentials. It is root-only. The external SSD is not encrypted, so treat
physical possession of it as possession of the server's recovery credentials.

## Reading the old data VHD from a NixOS installer

The following is a read-only recovery outline. Confirm device identities and
paths again before running it; installer device names are not guaranteed.

```sh
sudo vgchange -ay XSLocalEXT-44ab286b-ed50-8661-bcef-2027159260c3

sudo mkdir -p /mnt/xcp-sr /mnt/old-data
sudo mount -o ro,noload \
  /dev/mapper/XSLocalEXT--44ab286b--ed50--8661--bcef--2027159260c3-44ab286b--ed50--8661--bcef--2027159260c3 \
  /mnt/xcp-sr

sudo modprobe nbd max_part=16
sudo qemu-nbd --read-only --format=vpc --connect=/dev/nbd0 \
  /mnt/xcp-sr/123fb967-bbe7-41eb-a092-664bcff6ad69.vhd

sudo blockdev --getsize64 /dev/nbd0
sudo mount -o ro,noload /dev/nbd0 /mnt/old-data
```

The reported NBD size should be `1649267441664` bytes. Verify these paths before
installing anything:

```sh
sudo test -f /mnt/old-data/migration-backup/baremetal-bootstrap/ssh_host_ed25519_key
sudo test -d /mnt/old-data/migration-backup/baremetal-bootstrap/nix-config/.git
sudo ls -la /mnt/old-data
```

Read-only cleanup:

```sh
sudo umount /mnt/old-data
sudo qemu-nbd --disconnect /dev/nbd0
sudo umount /mnt/xcp-sr
sudo vgchange -an XSLocalEXT-44ab286b-ed50-8661-bcef-2027159260c3
```

## Configuration changes required for bare metal

The repository now contains three migration-specific configurations:

- `polaris-installer`: guarded bootable ISO with the recovery helpers and a
  copy of this repository.
- `polaris-bootstrap`: deliberately minimal first-boot system with networking
  and SSH, but none of the production services.
- `polaris-baremetal`: the eventual full Polaris service configuration for the
  physical EliteDesk.

The full target selects label-based `NIXOS_ROOT`, `NIXOS_BOOT`, and
`POLARIS_DATA` filesystems, disables Xen guest utilities, and enables the Intel
microcode, graphics/media firmware, `e1000e`, and `kvm-intel` support. Do not
switch to it until the external data disk has been converted to its final
`POLARIS_DATA` filesystem and restored.

Build all three without changing the running system:

```sh
nix build --no-link .#nixosConfigurations.polaris-baremetal.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.polaris-bootstrap.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.polaris-installer.config.system.build.isoImage
```

## Database maintenance before cutover

PostgreSQL reported that the `postgres` and `zipline` databases were created
with glibc collation version 2.40 while the current system provides 2.42. Both
databases were reindexed and refreshed on 2026-08-08. The subsequent
`pg_dumpall --schema-only` completed without a collation warning, and Zipline
restarted successfully.

```sh
sudo systemctl stop zipline.service
sudo -u postgres psql -X --set ON_ERROR_STOP=1 -d zipline \
  -c 'REINDEX DATABASE zipline;'
sudo -u postgres psql -X --set ON_ERROR_STOP=1 -d postgres \
  -c 'ALTER DATABASE zipline REFRESH COLLATION VERSION;'
sudo -u postgres psql -X --set ON_ERROR_STOP=1 -d postgres \
  -c 'REINDEX DATABASE postgres;'
sudo -u postgres psql -X --set ON_ERROR_STOP=1 -d postgres \
  -c 'ALTER DATABASE postgres REFRESH COLLATION VERSION;'
sudo systemctl start zipline.service
sudo -u postgres pg_dumpall --schema-only >/dev/null
```

## Network identity

The VM currently uses `192.168.1.82` with virtual MAC
`12:53:b7:f3:88:ae`. XCP-ng and the physical NIC use `192.168.1.173` and
MAC `38:22:e2:0c:1e:5a`.

Keeping `192.168.1.82` on bare metal is the least disruptive choice because:

- Mosquitto binds directly to `192.168.1.82`.
- Home Assistant advertises `http://192.168.1.82:8123` internally.
- Local DNS points `voice.skulldogged.dev` to `192.168.1.82`.
- LAN clients may use Polaris for DNS and local services.

The FiOS router is not administratively accessible, so both the bootstrap and
final bare-metal configurations assign `192.168.1.82/24` statically to the
physical MAC `38:22:e2:0c:1e:5a`, with gateway `192.168.1.1`. The VM must be
stopped before bare metal boots so the two systems never claim the address at
the same time.

## Prepared handoff tooling

`migration/polaris/xcp-handoff.sh` is installed on XCP-ng as
`/root/polaris-xcp-handoff`. Its check mode validates the exact EliteDesk,
internal NVMe, Polaris VM/root VDI, external SR, protected data VHD, and free
space without changing state:

```sh
/root/polaris-xcp-handoff --check
```

Execution is intentionally separate. It asks XCP-ng to shut down Polaris,
copies the stopped 400 GiB root VDI to the external SR, validates the copy and
writes a completion marker. If the copy fails after shutdown, it attempts to
restart Polaris. This command must only be launched when the installer ISO and
remote console are ready:

```sh
systemd-run --unit=polaris-cutover --property=Type=oneshot \
  /root/polaris-xcp-handoff --execute MXL0124GTB --power-off-on-success
```

Running it through the XCP-ng service manager lets the copy finish after this
VM—and therefore this shell—has shut down. Progress is recorded in
`/run/sr-mount/44ab286b-ed50-8661-bcef-2027159260c3/polaris-cutover/xcp-handoff.log`.

The installer provides two commands:

- `polaris-open-old-data` performs an entirely read-only, identity-checked
  mount of the external SR and data VHD.
- `polaris-install-bootstrap` repeats all hardware and rollback checks, copies
  recovery material into RAM, disconnects the external disk, and then requires
  the exact interactive phrase `ERASE-CF0292Y000498` before it will touch the
  internal NVMe.

## Cutover order

Preparation (safe to do while the VM is live):

1. Commit and push the complete Nix configuration, then rebuild the final ISO.
2. Put `polaris-migration.iso` in NanoKVM virtual media and verify that AMT or
   NanoKVM provides a working remote console. Do not boot it yet.
3. Confirm the bootstrap and final bare-metal configurations still assign
   `192.168.1.82/24` to physical MAC `38:22:e2:0c:1e:5a`; do not boot either
   while the VM still owns that address.
4. Run the expanded Restic backup and repository check one final time. Verify
   `/mnt/migration-backup/baremetal-bootstrap` exists and contains the SSH host
   key and Git working tree.
5. Run `/root/polaris-xcp-handoff --check` on XCP-ng again.

Irreversible cutover begins only after explicitly choosing to run it:

6. Keep the remote console open and launch the `systemd-run` handoff command
   above. Polaris will disappear when the VM shuts down; wait for XCP-ng to
   power itself off after the verified VDI copy.
7. Power on through AMT, select the mounted installer ISO, and boot it in UEFI
   mode.
8. At the installer shell, first run `sudo polaris-open-old-data` if a final
   manual read-only inspection is wanted. Reboot before installation if that
   helper was run, so the guarded installer starts from a clean state.
9. Run `sudo polaris-install-bootstrap`, inspect every identity it prints, and
   enter its exact erase phrase only when ready. The external SPCC disk is
   detached before the NVMe is erased.
10. Remove the virtual ISO and reboot. The minimal system should obtain
    `192.168.1.82` and permit key-only SSH using the restored host identity.

Recovery and final service cutover happen from the new bootstrap system:

11. Mount the external SR/data VHD read-only, copy its approximately 123 GiB of
    data temporarily onto the NVMe, and restore/test service state from Restic.
12. Only after the temporary copy and Restic restore are verified, reformat the
    external SSD as a direct ext4 filesystem labeled `POLARIS_DATA`, then copy
    the data back.
13. Build and switch to `polaris-baremetal`, then verify public endpoints, LAN
    DNS, Tailscale, AMT, a normal reboot, and AC-power recovery.
14. Retain XCP-ng rollback VHDs and the stopped CoreOS VM until those tests have
    passed. Delete them only in a later, separately reviewed cleanup.
