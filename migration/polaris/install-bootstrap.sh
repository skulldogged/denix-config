# Install the guarded, minimal first-boot Polaris system onto the verified NVMe.
set -euo pipefail

expected_vendor=HP
expected_product='HP EliteDesk 800 G5 Desktop Mini'
expected_machine_serial=MXL0124GTB
target=/dev/nvme0n1
expected_target_serial=CF0292Y000498
expected_target_size=512110190592
expected_source_vdi_uuid=287f12ba-f4ad-4bf7-92b1-624044302e78
expected_source_vdi_size=429496729600
sr_mount=/mnt/xcp-sr
data_mount=/mnt/old-data
recovery=/run/polaris-bootstrap
embedded_repo=/etc/polaris-migration/nix-config

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

read_trimmed() {
  local path=$1
  local value
  value=$(< "$path")
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

[[ $EUID -eq 0 ]] || die 'polaris-install-bootstrap must run as root'
[[ -t 0 ]] || die 'an interactive terminal is required for the erase confirmation'
[[ -d /sys/firmware/efi ]] || die 'installer was not booted in UEFI mode'

[[ "$(read_trimmed /sys/class/dmi/id/sys_vendor)" == "$expected_vendor" ]] || \
  die 'system vendor does not match the expected EliteDesk'
[[ "$(read_trimmed /sys/class/dmi/id/product_name)" == "$expected_product" ]] || \
  die 'product name does not match the expected EliteDesk'
[[ "$(read_trimmed /sys/class/dmi/id/product_serial)" == "$expected_machine_serial" ]] || \
  die 'machine serial does not match the expected EliteDesk'

[[ -b "$target" ]] || die "NVMe install target is missing: $target"
[[ "$(blockdev --getsize64 "$target")" == "$expected_target_size" ]] || \
  die 'NVMe size does not match the verified KingFast disk'
[[ "$(read_trimmed /sys/class/block/nvme0n1/device/serial)" == "$expected_target_serial" ]] || \
  die 'NVMe serial does not match the verified KingFast disk'

if lsblk -nrpo MOUNTPOINT "$target" | grep -q '[^[:space:]]'; then
  die 'one or more NVMe filesystems are mounted'
fi

printf 'Verified machine: %s, serial %s\n' "$expected_product" "$expected_machine_serial"
printf 'Verified erase target: %s, serial %s, %s bytes\n' \
  "$target" "$expected_target_serial" "$expected_target_size"

polaris-open-old-data

marker="$sr_mount/polaris-cutover/root-vdi-copy-complete"
[[ -f "$marker" ]] || die "stopped root-VDI rollback marker is missing: $marker"

copy_uuid=$(sed -n 's/^copied_vdi_uuid=//p' "$marker")
source_uuid=$(sed -n 's/^source_vdi_uuid=//p' "$marker")
virtual_size=$(sed -n 's/^virtual_size=//p' "$marker")

[[ "$source_uuid" == "$expected_source_vdi_uuid" ]] || \
  die 'rollback marker refers to the wrong source VDI'
[[ "$copy_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || \
  die 'rollback marker contains an invalid copied VDI UUID'
[[ "$virtual_size" == "$expected_source_vdi_size" ]] || \
  die 'rollback marker contains the wrong virtual disk size'

rollback_vhd="$sr_mount/$copy_uuid.vhd"
[[ -f "$rollback_vhd" ]] || die "copied root VHD is missing: $rollback_vhd"

qemu-img info --output=json -f vpc "$rollback_vhd" |
  jq -e --argjson size "$expected_source_vdi_size" \
    '.["virtual-size"] == $size and .format == "vpc"' >/dev/null || \
  die 'copied root VHD failed the format/virtual-size check'

bootstrap="$data_mount/migration-backup/baremetal-bootstrap"
key="$bootstrap/ssh_host_ed25519_key"
pub="$bootstrap/ssh_host_ed25519_key.pub"
[[ -f "$key" && -f "$pub" ]] || die 'recovery SSH host key pair is missing'

derived_pub=$(ssh-keygen -y -f "$key")
recorded_pub=$(cut -d ' ' -f 1,2 "$pub")
[[ "$derived_pub" == "$recorded_pub" ]] || die 'recovery SSH host key pair does not match'

[[ -d "$embedded_repo" ]] || die 'installer-embedded Nix configuration is missing'

[[ ! -e "$recovery" ]] || die "$recovery already exists; reboot the installer before retrying"
install -d -m 0700 "$recovery"
rsync -aHAX --numeric-ids "$bootstrap/" "$recovery/"
# Preserve the bootstrapped Git metadata and any local files while overlaying
# the configuration used to build this ISO.
rsync -a "$embedded_repo/" "$recovery/nix-config/"
install -m 0600 "$marker" "$recovery/root-vdi-copy-complete"

printf '\nThe stopped root VDI copy and bootstrap material are verified.\n'
printf 'The following disk will now be completely erased:\n\n'
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS "$target"
printf '\nType exactly ERASE-%s to continue: ' "$expected_target_serial"
read -r confirmation
[[ "$confirmation" == "ERASE-$expected_target_serial" ]] || die 'confirmation did not match; nothing was erased'

# The recovery material is now in installer RAM, so detach the protected disk
# before performing any destructive operation on the independently verified
# NVMe target.
umount "$data_mount"
qemu-nbd --disconnect /dev/nbd0
umount "$sr_mount"
vgchange -an XSLocalEXT-44ab286b-ed50-8661-bcef-2027159260c3 >/dev/null

if swapon --show=NAME --noheadings | grep -Fxq "${target}p6"; then
  swapoff "${target}p6"
fi

if vgs --noheadings -o vg_name | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
   grep -Fxq VG_XenStorage-bbc07b3e-07ff-ade0-df04-9e6ff186d294; then
  vgchange -an VG_XenStorage-bbc07b3e-07ff-ade0-df04-9e6ff186d294 >/dev/null
fi

wipefs --all --force "$target"
sgdisk --zap-all "$target"
sgdisk \
  --new=1:1MiB:+1GiB \
  --typecode=1:EF00 \
  --change-name=1:NIXOS_BOOT \
  --new=2:0:0 \
  --typecode=2:8300 \
  --change-name=2:NIXOS_ROOT \
  "$target"

partprobe "$target"
udevadm settle
[[ -b "${target}p1" && -b "${target}p2" ]] || die 'new NVMe partitions did not appear'

mkfs.fat -F 32 -n NIXOS_BOOT "${target}p1"
mkfs.ext4 -F -L NIXOS_ROOT "${target}p2"

mount "${target}p2" /mnt
install -d -m 0755 /mnt/boot
mount "${target}p1" /mnt/boot

nixos-install \
  --flake "path:$embedded_repo#polaris-bootstrap" \
  --no-root-passwd

install -d -m 0700 /mnt/etc/ssh
install -m 0600 "$recovery/ssh_host_ed25519_key" /mnt/etc/ssh/ssh_host_ed25519_key
install -m 0644 "$recovery/ssh_host_ed25519_key.pub" /mnt/etc/ssh/ssh_host_ed25519_key.pub

install -d -o 1000 -g 100 -m 0750 /mnt/home/marshall
rsync -aHAX --numeric-ids "$recovery/nix-config/" /mnt/home/marshall/nix-config/
chown -R 1000:100 /mnt/home/marshall/nix-config

install -d -m 0700 /mnt/root/polaris-migration
install -m 0600 "$recovery/root-vdi-copy-complete" \
  /mnt/root/polaris-migration/root-vdi-copy-complete

sync
printf '\nBootstrap installation completed successfully.\n'
printf 'The external SPCC disk was never written to and is now detached.\n'
printf 'Remove/unmount the installer ISO and run reboot when ready.\n'
