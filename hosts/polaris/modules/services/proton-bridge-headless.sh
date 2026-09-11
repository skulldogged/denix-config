#!/usr/bin/env bash
set -euo pipefail
umask 077
state=/home/marshall/.local/share/proton-bridge-headless
export GNUPGHOME="$state/gnupg"
export PASSWORD_STORE_DIR="$state/password-store"
export XDG_CONFIG_HOME="$state/config"
export XDG_CACHE_HOME="$state/cache"
export XDG_DATA_HOME="$state/data"
export PATH="$state/pass-package/bin:/run/current-system/sw/bin:$PATH"
# Bridge probes Secret Service even when pass is preferred. Keep that probe
# independent of any logged-in desktop and let it use the dedicated pass store.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/proton-bridge-headless
pass show .bridge-health >/dev/null
if [ "${1:-}" = login ]; then
  systemctl --user stop protonmail-bridge.service
  trap 'systemctl --user start protonmail-bridge.service' EXIT
  protonmail-bridge --cli
else
  exec protonmail-bridge --noninteractive
fi
