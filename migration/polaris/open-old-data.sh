# Mount the protected XCP-ng data VHD read-only from the migration ISO.
set -euo pipefail

expected_external_serial=AA000000000000003076
expected_external_size=2048408248320
vg_name=XSLocalEXT-44ab286b-ed50-8661-bcef-2027159260c3
data_vhd_uuid=123fb967-bbe7-41eb-a092-664bcff6ad69
expected_data_size=1649267441664
sr_mount=/mnt/xcp-sr
data_mount=/mnt/old-data
nbd_device=/dev/nbd0

if [[ $EUID -ne 0 ]]; then
  printf 'polaris-open-old-data must run as root\n' >&2
  exit 1
fi

if mountpoint -q "$data_mount"; then
  if [[ "$(findmnt -n -o SOURCE --target "$data_mount")" != "$nbd_device" ]]; then
    printf '%s is already mounted from an unexpected source\n' "$data_mount" >&2
    exit 1
  fi

  printf 'Old data is already available read-only at %s\n' "$data_mount"
  exit 0
fi

shopt -s nullglob
matches=()
for link in /dev/disk/by-id/*"$expected_external_serial"*; do
  [[ -L "$link" ]] || continue
  candidate=$(readlink -f -- "$link")
  [[ -b "$candidate" ]] || continue
  [[ "$(blockdev --getsize64 "$candidate")" == "$expected_external_size" ]] || continue
  matches+=("$candidate")
done

mapfile -t external_devices < <(printf '%s\n' "${matches[@]}" | sort -u)
if [[ ${#external_devices[@]} -ne 1 ]]; then
  printf 'Expected exactly one protected SPCC disk, found %s\n' "${#external_devices[@]}" >&2
  exit 1
fi
external_device=${external_devices[0]}

if [[ "$external_device" == /dev/nvme0n1 ]]; then
  printf 'Protected external disk unexpectedly resolved to the NVMe target\n' >&2
  exit 1
fi

printf 'Protected external disk: %s (%s bytes)\n' \
  "$external_device" "$(blockdev --getsize64 "$external_device")"

modprobe nbd max_part=16
vgchange -ay "$vg_name" >/dev/null

mapfile -t lv_paths < <(
  lvs --noheadings -o lv_path --select "vg_name=$vg_name" |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
    grep '^/'
)
if [[ ${#lv_paths[@]} -ne 1 ]] || [[ ! -b "${lv_paths[0]}" ]]; then
  printf 'Could not resolve the single external SR logical volume\n' >&2
  exit 1
fi
sr_device=${lv_paths[0]}

mkdir -p "$sr_mount" "$data_mount"
if mountpoint -q "$sr_mount"; then
  mounted_source=$(readlink -f -- "$(findmnt -n -o SOURCE --target "$sr_mount")")
  if [[ "$mounted_source" != "$(readlink -f -- "$sr_device")" ]]; then
    printf '%s is already mounted from an unexpected source\n' "$sr_mount" >&2
    exit 1
  fi
else
  mount -o ro,noload "$sr_device" "$sr_mount"
fi

vhd_path="$sr_mount/$data_vhd_uuid.vhd"
if [[ ! -f "$vhd_path" ]]; then
  printf 'Expected data VHD is missing: %s\n' "$vhd_path" >&2
  exit 1
fi

if [[ -r /sys/block/nbd0/pid ]] && [[ -s /sys/block/nbd0/pid ]]; then
  printf '%s is already connected; refusing to replace it\n' "$nbd_device" >&2
  exit 1
fi

connected=false
cleanup_on_error() {
  status=$?
  if [[ $status -ne 0 ]] && [[ $connected == true ]]; then
    qemu-nbd --disconnect "$nbd_device" >/dev/null 2>&1 || true
  fi
  return "$status"
}
trap cleanup_on_error EXIT

qemu-nbd --read-only --format=vpc --connect="$nbd_device" "$vhd_path"
connected=true
udevadm settle

actual_data_size=$(blockdev --getsize64 "$nbd_device")
if [[ "$actual_data_size" != "$expected_data_size" ]]; then
  printf 'Data VHD size mismatch: expected %s, got %s\n' \
    "$expected_data_size" "$actual_data_size" >&2
  exit 1
fi

mount -o ro,noload "$nbd_device" "$data_mount"

bootstrap="$data_mount/migration-backup/baremetal-bootstrap"
if [[ ! -f "$bootstrap/ssh_host_ed25519_key" ]] || \
   [[ ! -d "$bootstrap/nix-config/.git" ]]; then
  printf 'Bare-metal bootstrap material is incomplete inside the data VHD\n' >&2
  exit 1
fi

trap - EXIT
printf 'External SR mounted read-only at %s\n' "$sr_mount"
printf 'Old data mounted read-only at %s\n' "$data_mount"
printf 'Bootstrap verified at %s\n' "$bootstrap"
