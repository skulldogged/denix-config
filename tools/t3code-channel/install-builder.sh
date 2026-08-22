#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir"

ln -sfn "$script_dir/systemd/t3code-channel-update.service" \
  "$unit_dir/t3code-channel-update.service"
ln -sfn "$script_dir/systemd/t3code-channel-update.timer" \
  "$unit_dir/t3code-channel-update.timer"

systemctl --user daemon-reload
systemctl --user enable --now t3code-channel-update.timer
systemctl --user status t3code-channel-update.timer --no-pager
