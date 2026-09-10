#!/usr/bin/env bash
set -euo pipefail

export PATH="/nix/var/nix/profiles/default/bin:$PATH"

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+$ ]]; then
  echo "Usage: deploy.sh VERSION" >&2
  exit 1
fi

version="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
denix_repo="$(cd -- "$script_dir/../.." && pwd)"
state_dir="${T3CODE_CHANNEL_STATE_DIR:-$HOME/.local/state/t3code-channel}"
release_dir="$state_dir/releases/$version"
fork_repo="${T3CODE_CHANNEL_FORK_REPO:-skulldogged/t3code}"
tag="personal-v${version}"
polaris_key="${T3CODE_CHANNEL_POLARIS_KEY:-$HOME/.ssh/rovefs_polaris_ed25519}"
polaris_host="${T3CODE_CHANNEL_POLARIS_HOST:-polaris}"
polaris_port="${T3CODE_CHANNEL_POLARIS_PORT:-2223}"
canis_key="${T3CODE_CHANNEL_CANIS_KEY:-$HOME/.ssh/id_ed25519_canis_t3}"
canis_host="${T3CODE_CHANNEL_CANIS_HOST:-marshall@100.87.212.76}"

log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

active_linux_version() {
  node -e 'const s=require(process.argv[1]); process.stdout.write(s.activeVersion)' "$1/runtime/service-state.json"
}

install_linux_candidate() {
  local base_dir="$1"
  local server_tgz="$2"
  local target_dir="$base_dir/runtime/versions/$version"
  local service_environment
  local service_exec_start
  local install_path
  if [[ -f "$target_dir/.install-complete" ]] && [[ "$(<"$target_dir/.install-complete")" == "$version" ]]; then
    return
  fi

  service_environment="$(systemctl --user show t3code.service -p Environment --value)"
  if [[ "$service_environment" =~ (^|[[:space:]])PATH=([^[:space:]]+) ]]; then
    install_path="${BASH_REMATCH[2]}"
  else
    service_exec_start="$(systemctl --user show t3code.service -p ExecStart --value)"
    if [[ ! "$service_exec_start" =~ path=([^[:space:]\;]+) ]]; then
      log "Could not determine the T3 service Node runtime."
      return 1
    fi
    install_path="$(dirname -- "${BASH_REMATCH[1]}"):$PATH"
  fi
  mkdir -p "$target_dir"
  PATH="$install_path" node -e '
    const fs = require("node:fs");
    fs.writeFileSync(process.argv[1], `${JSON.stringify({ private: true }, null, 2)}\n`);
  ' "$target_dir/package.json"
  PATH="$install_path" npm install --prefix "$target_dir" --omit=dev --no-audit --no-fund "$server_tgz"
  printf '%s\n' "$version" > "$target_dir/.install-complete"
}

mkdir -p "$release_dir"
log "Downloading and verifying release assets for ${version}."
gh release download "$tag" --repo "$fork_repo" --dir "$release_dir" --clobber
(
  cd "$release_dir"
  sha256sum --check SHA256SUMS
)

server_tgz="$release_dir/t3-${version}.tgz"
shopt -s nullglob
app_images=("$release_dir"/T3-Code-*-x86_64.AppImage)
shopt -u nullglob
if [[ ${#app_images[@]} -ne 1 ]]; then
  log "Expected exactly one AppImage in the release; found ${#app_images[@]}."
  exit 1
fi
app_image="${app_images[0]}"
if [[ ! -f "$server_tgz" ]]; then
  log "The release is missing the server package."
  exit 1
fi

deployment_failed=0
deployment_busy=0
deploy_polaris() {
  local polaris_cache=".cache/t3code-channel/$version"
  local polaris_current
  ssh -i "$polaris_key" -p "$polaris_port" -o IdentitiesOnly=yes -o BatchMode=yes \
    "$polaris_host" "mkdir -p '$polaris_cache'" || return $?
  scp -i "$polaris_key" -P "$polaris_port" -o IdentitiesOnly=yes -o BatchMode=yes \
    "$server_tgz" "$script_dir/switch-service.mjs" "$script_dir/check-idle.mjs" "$script_dir/renumbering.mjs" "$polaris_host:$polaris_cache/" || return $?
  polaris_current="$(ssh -i "$polaris_key" -p "$polaris_port" -o IdentitiesOnly=yes -o BatchMode=yes \
    "$polaris_host" "node -e 'const s=require(\"./.t3/runtime/service-state.json\"); process.stdout.write(s.activeVersion)'")" || return $?
  ssh -i "$polaris_key" -p "$polaris_port" -o IdentitiesOnly=yes -o BatchMode=yes \
    "$polaris_host" bash -s -- "$version" "$polaris_current" "$polaris_cache/$(basename "$server_tgz")" "$polaris_cache/switch-service.mjs" "$polaris_cache/check-idle.mjs" <<'POLARIS'
set -euo pipefail
version="$1"
current="$2"
server_tgz="$3"
switch_script="$4"
check_idle_script="$5"
target_dir="$HOME/.t3/runtime/versions/$version"
if [[ ! -f "$target_dir/.install-complete" ]] || [[ "$(<"$target_dir/.install-complete")" != "$version" ]]; then
  service_environment="$(systemctl --user show t3code.service -p Environment --value)"
  if [[ "$service_environment" =~ (^|[[:space:]])PATH=([^[:space:]]+) ]]; then
    install_path="${BASH_REMATCH[2]}"
  else
    service_exec_start="$(systemctl --user show t3code.service -p ExecStart --value)"
    if [[ ! "$service_exec_start" =~ path=([^[:space:]\;]+) ]]; then
      echo "Could not determine the T3 service Node runtime." >&2
      exit 1
    fi
    install_path="$(dirname -- "${BASH_REMATCH[1]}"):$PATH"
  fi
  mkdir -p "$target_dir"
  PATH="$install_path" node -e 'const fs=require("node:fs"); fs.writeFileSync(process.argv[1], JSON.stringify({private:true}, null, 2)+"\n")' "$target_dir/package.json"
  PATH="$install_path" npm install --prefix "$target_dir" --omit=dev --no-audit --no-fund "$server_tgz"
  printf '%s\n' "$version" > "$target_dir/.install-complete"
fi
if [[ "$current" != "$version" ]]; then
  node "$switch_script" "$HOME/.t3" "$current" "$version" t3code.service --allow-personal-renumbering
fi
POLARIS
  polaris_status=$?
  return "$polaris_status"
}

log "Installing and switching Polaris."
set +e
deploy_polaris
polaris_status=$?
set -e
if (( polaris_status == 75 )); then
  log "Polaris has active turns; deferring its service switch."
  deployment_busy=1
elif (( polaris_status != 0 )); then
  log "Polaris deployment failed with status ${polaris_status}; continuing with Navis, Canis, and Builder."
  deployment_failed=1
fi

deploy_canis() {
  local canis_cache=".cache/t3code-channel/$version"
  local -a ssh_options=(
    -i "$canis_key"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=2
  )

  ssh "${ssh_options[@]}" "$canis_host" "mkdir -p '$canis_cache'" || return $?
  scp "${ssh_options[@]}" "$server_tgz" "$script_dir/check-idle.mjs" "$canis_host:$canis_cache/" || return $?
  ssh "${ssh_options[@]}" "$canis_host" bash -s -- \
    "$version" "$canis_cache/$(basename "$server_tgz")" "$canis_cache/check-idle.mjs" <<'CANIS'
set -euo pipefail
version="$1"
server_tgz="$2"
check_idle_script="$3"
install_root="$HOME/.local/share/t3code"
target_dir="$install_root/$version"
plist="$HOME/Library/LaunchAgents/codes.t3.server.plist"
backup="$plist.before-$version"
database="$HOME/.local/share/t3code/userdata/state.sqlite"
database_backup="${backup}.database"
node_bin="/opt/homebrew/opt/node@24/bin/node"
npm_bin="/opt/homebrew/opt/node@24/bin/npm"
export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
entry="$target_dir/node_modules/t3/dist/bin.mjs"

if [[ ! -f "$target_dir/.install-complete" ]] || [[ "$(<"$target_dir/.install-complete")" != "$version" ]]; then
  mkdir -p "$target_dir"
  "$node_bin" -e 'const fs=require("node:fs"); fs.writeFileSync(process.argv[1], JSON.stringify({private:true}, null, 2)+"\n")' "$target_dir/package.json"
  "$npm_bin" install --prefix "$target_dir" --omit=dev --no-audit --no-fund "$server_tgz"
  printf '%s\n' "$version" > "$target_dir/.install-complete"
fi

current_entry="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$plist")"
if [[ "$current_entry" == "$entry" ]]; then
  exit 0
fi

node "$check_idle_script" "$HOME/.local/share/t3code/userdata/state.sqlite"
cp "$plist" "$backup"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $entry" "$plist"
if ! launchctl bootout "gui/$(id -u)/codes.t3.server"; then
  cp "$backup" "$plist"
  echo "Could not stop the existing server; leaving its database untouched." >&2
  exit 1
fi
sleep 8

resume_original() {
  cp "$backup" "$plist"
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

restore_old() {
  if launchctl print "gui/$(id -u)/codes.t3.server" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/codes.t3.server" || return 1
    sleep 8
  fi
  for suffix in "" -wal -shm; do
    if [[ -f "$database_backup/state.sqlite$suffix" ]]; then
      cp "$database_backup/state.sqlite$suffix" "$database$suffix"
    else
      rm -f "$database$suffix"
    fi
  done
  cp "$backup" "$plist"
  sleep 8
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

database_backup="$(mktemp -d "${backup}.database.XXXXXX")" || {
  resume_original
  exit 1
}
for suffix in "" -wal -shm; do
  if [[ -f "$database$suffix" ]]; then
    if ! cp "$database$suffix" "$database_backup/state.sqlite$suffix"; then
      resume_original
      exit 1
    fi
  elif [[ -n "$suffix" ]]; then
    :
  else
    resume_original
    exit 1
  fi
done
sleep 8
if ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
  restore_old
  exit 1
fi

for attempt in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:3773/ >/dev/null; then
    exit 0
  fi
  sleep 2
done

restore_old
exit 1
CANIS
}

log "Installing and switching Canis."
set +e
deploy_canis
canis_status=$?
set -e
if (( canis_status == 75 )); then
  log "Canis has active turns; deferring its service switch."
  deployment_busy=1
elif (( canis_status != 0 )); then
  log "Canis deployment failed with status ${canis_status}; continuing with Navis and Builder."
  deployment_failed=1
fi

log "Updating the Navis Nix pin in denix-config."
git -C "$denix_repo" fetch origin main
git -C "$denix_repo" merge --ff-only origin/main
if [[ -n "$(git -C "$denix_repo" status --porcelain --untracked-files=no)" ]]; then
  log "denix-config has tracked changes; refusing to update the client pin."
  exit 1
fi
app_image_hash="$(nix hash file --type sha256 --sri "$app_image")"
release_json="$denix_repo/modules/home/t3code-release.json"
node -e '
  const fs = require("node:fs");
  const [file, version, appImageHash, repository] = process.argv.slice(1);
  fs.writeFileSync(file, `${JSON.stringify({
    version,
    appImageHash,
    repository,
    tagPrefix: "personal-v",
  }, null, 2)}\n`);
' "$release_json" "$version" "$app_image_hash" "$fork_repo"
git -C "$denix_repo" add modules/home/t3code-release.json
if ! git -C "$denix_repo" diff --cached --quiet; then
  git -C "$denix_repo" commit -m "update T3 Code personal channel to ${version}"
  git -C "$denix_repo" push origin main
fi

log "Installing and switching Builder last."
builder_base="$HOME/.t3"
builder_current="$(active_linux_version "$builder_base")"
install_linux_candidate "$builder_base" "$server_tgz"
if [[ "$builder_current" != "$version" ]]; then
  set +e
  node "$script_dir/switch-service.mjs" "$builder_base" "$builder_current" "$version" t3code.service --allow-personal-renumbering
  builder_status=$?
  set -e
  if (( builder_status == 75 )); then
    log "Builder has active turns; deferring its service switch."
    deployment_busy=1
  elif (( builder_status != 0 )); then
    log "Builder deployment failed with status ${builder_status}."
    deployment_failed=1
  fi
fi

if (( deployment_failed != 0 )); then
  log "At least one fleet target failed; deferred busy targets remain pending."
  exit 1
fi

if (( deployment_busy != 0 )); then
  log "The available machines were updated; busy fleet targets remain pending."
  exit 75
fi

log "Builder, Polaris, and Canis are on ${version}; the Navis pin is published."
