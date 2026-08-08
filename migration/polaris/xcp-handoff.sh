#!/bin/bash
# Run on XCP-ng to create a stopped root-VDI rollback copy before cutover.
set -euo pipefail

expected_vendor=HP
expected_product='HP EliteDesk 800 G5 Desktop Mini'
expected_machine_serial=MXL0124GTB
expected_nvme_serial=CF0292Y000498
expected_nvme_size=512110190592

vm_uuid=af788520-36c6-6d21-6f08-f465c965332c
expected_vm_name=NixOS
source_vdi_uuid=287f12ba-f4ad-4bf7-92b1-624044302e78
source_sr_uuid=bbc07b3e-07ff-ade0-df04-9e6ff186d294
expected_virtual_size=429496729600
target_sr_uuid=44ab286b-ed50-8661-bcef-2027159260c3
sr_mount=/run/sr-mount/44ab286b-ed50-8661-bcef-2027159260c3
data_vhd_uuid=123fb967-bbe7-41eb-a092-664bcff6ad69
minimum_headroom=$((50 * 1024 * 1024 * 1024))

mode=check
power_off_on_success=false
approval=

usage() {
  cat <<'EOF'
Usage:
  polaris-xcp-handoff --check
  polaris-xcp-handoff --execute MXL0124GTB [--power-off-on-success]

--check performs read-only validation and leaves the VM untouched.
--execute cleanly shuts down Polaris and copies its root VDI to the external SR.
If any post-shutdown step fails, the script attempts to restart Polaris.
EOF
}

if [[ $# -gt 0 ]]; then
  case $1 in
    --check)
      [[ $# -eq 1 ]] || {
        usage >&2
        exit 2
      }
      ;;
    --execute)
      mode=execute
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      approval=$2
      shift 2
      if [[ $# -gt 0 ]]; then
        [[ $# -eq 1 && $1 == --power-off-on-success ]] || {
          usage >&2
          exit 2
        }
        power_off_on_success=true
      fi
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
fi

log() {
  printf '%s polaris-xcp-handoff: %s\n' "$(date -u +%FT%TZ)" "$*"
}

die() {
  log "ERROR: $*" >&2
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

xe_get() {
  local object=$1
  local uuid=$2
  local parameter=$3
  xe "$object-param-get" uuid="$uuid" param-name="$parameter"
}

[[ $EUID -eq 0 ]] || die 'must run as root on the XCP-ng host'
[[ "$(read_trimmed /sys/class/dmi/id/sys_vendor)" == "$expected_vendor" ]] || \
  die 'unexpected system vendor'
[[ "$(read_trimmed /sys/class/dmi/id/product_name)" == "$expected_product" ]] || \
  die 'unexpected system product'
[[ "$(read_trimmed /sys/class/dmi/id/product_serial)" == "$expected_machine_serial" ]] || \
  die 'unexpected system serial'

[[ -b /dev/nvme0n1 ]] || die 'expected NVMe disk is missing'
[[ "$(blockdev --getsize64 /dev/nvme0n1)" == "$expected_nvme_size" ]] || \
  die 'NVMe size does not match'
[[ "$(lsblk -dn -o SERIAL /dev/nvme0n1 | tr -d '[:space:]')" == "$expected_nvme_serial" ]] || \
  die 'NVMe serial does not match'

[[ "$(xe_get vm "$vm_uuid" name-label)" == "$expected_vm_name" ]] || \
  die 'VM UUID does not resolve to the expected NixOS VM'
[[ "$(xe_get vdi "$source_vdi_uuid" sr-uuid)" == "$source_sr_uuid" ]] || \
  die 'source VDI is no longer on the verified internal SR'
[[ "$(xe_get vdi "$source_vdi_uuid" virtual-size)" == "$expected_virtual_size" ]] || \
  die 'source VDI virtual size changed'

mapfile -t matching_vbds < <(
  xe vbd-list vm-uuid="$vm_uuid" vdi-uuid="$source_vdi_uuid" \
    params=uuid --minimal |
    tr ',' '\n' |
    grep -E '^[0-9a-f-]{36}$'
)
[[ ${#matching_vbds[@]} -eq 1 ]] || die 'source VDI is not attached exactly once to Polaris'

[[ "$(xe_get sr "$target_sr_uuid" type)" == ext ]] || die 'target SR is not ext-backed'
mountpoint -q "$sr_mount" || die 'target external SR is not mounted'
[[ -f "$sr_mount/$data_vhd_uuid.vhd" ]] || die 'protected data VHD is missing from the external SR'

available=$(df -B1 --output=avail "$sr_mount" | tail -1 | tr -d '[:space:]')
required=$((expected_virtual_size + minimum_headroom))
[[ "$available" =~ ^[0-9]+$ ]] || die 'could not determine target SR free space'
((available >= required)) || die "target SR has only $available bytes free; $required required"

log "validated XCP-ng host $expected_product ($expected_machine_serial)"
log "validated Polaris VM $vm_uuid and root VDI $source_vdi_uuid"
log "validated external SR $target_sr_uuid with $available bytes free"

if [[ $mode == check ]]; then
  log 'read-only checks passed; no VM or disk state was changed'
  exit 0
fi

[[ "$approval" == "$expected_machine_serial" ]] || die 'execution approval token is incorrect'
[[ "$(xe_get vm "$vm_uuid" power-state)" == running ]] || die 'Polaris must be running before handoff'

log_dir="$sr_mount/polaris-cutover"
marker="$log_dir/root-vdi-copy-complete"
[[ ! -e "$marker" ]] || die "completion marker already exists: $marker"
mkdir -p "$log_dir"
chmod 0700 "$log_dir"
exec > >(tee -a "$log_dir/xcp-handoff.log") 2>&1

vm_stopped=false
copy_complete=false
recover_on_failure() {
  status=$?
  if [[ $status -ne 0 && $vm_stopped == true && $copy_complete == false ]]; then
    log 'handoff failed after VM shutdown; attempting to restart Polaris'
    if xe vm-start uuid="$vm_uuid"; then
      log 'Polaris restart request succeeded'
    else
      log 'ERROR: Polaris could not be restarted automatically'
    fi
  fi
  exit "$status"
}
trap recover_on_failure EXIT

log 'requesting a clean Polaris shutdown'
timeout 5m xe vm-shutdown uuid="$vm_uuid"
[[ "$(xe_get vm "$vm_uuid" power-state)" == halted ]] || die 'Polaris did not reach the halted state'
vm_stopped=true
sync

log 'copying the stopped Polaris root VDI to the external SR'
copy_uuid=$(xe vdi-copy uuid="$source_vdi_uuid" sr-uuid="$target_sr_uuid")
[[ "$copy_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || \
  die 'xe vdi-copy returned an invalid UUID'

[[ "$(xe_get vdi "$copy_uuid" sr-uuid)" == "$target_sr_uuid" ]] || \
  die 'copied VDI was not registered on the target SR'
[[ "$(xe_get vdi "$copy_uuid" virtual-size)" == "$expected_virtual_size" ]] || \
  die 'copied VDI virtual size does not match the source'

rollback_vhd="$sr_mount/$copy_uuid.vhd"
[[ -f "$rollback_vhd" ]] || die 'copied VDI file is missing from the external SR'
[[ "$(vhd-util query -v -n "$rollback_vhd")" == 409600 ]] || \
  die 'copied VHD reports the wrong virtual size'
vhd-util query -p -n "$rollback_vhd" | grep -Fq 'has no parent' || \
  die 'copied root VHD unexpectedly depends on a parent'

xe vdi-param-set uuid="$copy_uuid" \
  name-label="Polaris stopped-root rollback $(date -u +%F)"

marker_tmp="$log_dir/.root-vdi-copy-complete.$$"
{
  printf 'source_vdi_uuid=%s\n' "$source_vdi_uuid"
  printf 'copied_vdi_uuid=%s\n' "$copy_uuid"
  printf 'virtual_size=%s\n' "$expected_virtual_size"
  printf 'physical_file_size=%s\n' "$(stat -c %s "$rollback_vhd")"
  printf 'completed_at=%s\n' "$(date -u +%FT%TZ)"
} > "$marker_tmp"
chmod 0600 "$marker_tmp"
mv "$marker_tmp" "$marker"
sync

copy_complete=true
trap - EXIT
log "root VDI copy completed and verified as $copy_uuid"
log "completion marker written to $marker"

if [[ $power_off_on_success == true ]]; then
  log 'copy succeeded; powering off the XCP-ng host as explicitly requested'
  systemctl poweroff
else
  log 'XCP-ng remains online and Polaris remains halted for inspection'
fi
