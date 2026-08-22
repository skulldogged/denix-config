#!/usr/bin/env bash
set -euo pipefail

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
tag="pi-v${version}"
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
  local install_path
  if [[ -f "$target_dir/.install-complete" ]] && [[ "$(<"$target_dir/.install-complete")" == "$version" ]]; then
    return
  fi

  service_environment="$(systemctl --user show t3code.service -p Environment --value)"
  if [[ ! "$service_environment" =~ (^|[[:space:]])PATH=([^[:space:]]+) ]]; then
    log "Could not determine the T3 service build environment."
    return 1
  fi
  install_path="${BASH_REMATCH[2]}"
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
app_image="$release_dir/T3-Code-${version}-x86_64.AppImage"
if [[ ! -f "$server_tgz" || ! -f "$app_image" ]]; then
  log "The release is missing the server package or AppImage."
  exit 1
fi

log "Installing and switching Polaris."
polaris_cache=".cache/t3code-channel/$version"
ssh -i "$polaris_key" -p "$polaris_port" -o IdentitiesOnly=yes -o BatchMode=yes \
  "$polaris_host" "mkdir -p '$polaris_cache'"
scp -i "$polaris_key" -P "$polaris_port" -o IdentitiesOnly=yes -o BatchMode=yes \
  "$server_tgz" "$script_dir/switch-service.mjs" "$polaris_host:$polaris_cache/"
polaris_current="$(ssh -i "$polaris_key" -p "$polaris_port" -o IdentitiesOnly=yes -o BatchMode=yes \
  "$polaris_host" "node -e 'const s=require(\"./.t3/runtime/service-state.json\"); process.stdout.write(s.activeVersion)'")"
ssh -i "$polaris_key" -p "$polaris_port" -o IdentitiesOnly=yes -o BatchMode=yes \
  "$polaris_host" bash -s -- "$version" "$polaris_current" "$polaris_cache/$(basename "$server_tgz")" "$polaris_cache/switch-service.mjs" <<'POLARIS'
set -euo pipefail
version="$1"
current="$2"
server_tgz="$3"
switch_script="$4"
target_dir="$HOME/.t3/runtime/versions/$version"
if [[ ! -f "$target_dir/.install-complete" ]] || [[ "$(<"$target_dir/.install-complete")" != "$version" ]]; then
  service_environment="$(systemctl --user show t3code.service -p Environment --value)"
  if [[ ! "$service_environment" =~ (^|[[:space:]])PATH=([^[:space:]]+) ]]; then
    echo "Could not determine the T3 service build environment." >&2
    exit 1
  fi
  install_path="${BASH_REMATCH[2]}"
  mkdir -p "$target_dir"
  PATH="$install_path" node -e 'const fs=require("node:fs"); fs.writeFileSync(process.argv[1], JSON.stringify({private:true}, null, 2)+"\n")' "$target_dir/package.json"
  PATH="$install_path" npm install --prefix "$target_dir" --omit=dev --no-audit --no-fund "$server_tgz"
  printf '%s\n' "$version" > "$target_dir/.install-complete"
fi
if [[ "$current" != "$version" ]]; then
  node "$switch_script" "$HOME/.t3" "$current" "$version"
fi
POLARIS

log "Installing and switching Canis."
canis_cache=".cache/t3code-channel/$version"
ssh -i "$canis_key" -o IdentitiesOnly=yes -o BatchMode=yes "$canis_host" "mkdir -p '$canis_cache'"
scp -i "$canis_key" -o IdentitiesOnly=yes -o BatchMode=yes \
  "$server_tgz" "$canis_host:$canis_cache/"
ssh -i "$canis_key" -o IdentitiesOnly=yes -o BatchMode=yes "$canis_host" bash -s -- \
  "$version" "$canis_cache/$(basename "$server_tgz")" <<'CANIS'
set -euo pipefail
version="$1"
server_tgz="$2"
install_root="$HOME/.local/share/t3code"
target_dir="$install_root/$version"
plist="$HOME/Library/LaunchAgents/codes.t3.server.plist"
backup="$plist.before-$version"
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

cp "$plist" "$backup"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $entry" "$plist"
launchctl bootout "gui/$(id -u)/codes.t3.server" >/dev/null 2>&1 || true
sleep 8
if ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
  cp "$backup" "$plist"
  launchctl bootstrap "gui/$(id -u)" "$plist"
  exit 1
fi

for attempt in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:3773/ >/dev/null; then
    exit 0
  fi
  sleep 2
done

launchctl bootout "gui/$(id -u)/codes.t3.server" >/dev/null 2>&1 || true
cp "$backup" "$plist"
sleep 8
launchctl bootstrap "gui/$(id -u)" "$plist"
exit 1
CANIS

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
    tagPrefix: "pi-v",
  }, null, 2)}\n`);
' "$release_json" "$version" "$app_image_hash" "$fork_repo"
git -C "$denix_repo" add modules/home/t3code-release.json
if ! git -C "$denix_repo" diff --cached --quiet; then
  git -C "$denix_repo" commit -m "update T3 Code Pi channel to ${version}"
  git -C "$denix_repo" push origin main
fi

log "Installing and switching Builder last."
builder_base="$HOME/.t3"
builder_current="$(active_linux_version "$builder_base")"
install_linux_candidate "$builder_base" "$server_tgz"
if [[ "$builder_current" != "$version" ]]; then
  node "$script_dir/switch-service.mjs" "$builder_base" "$builder_current" "$version"
fi

log "Builder, Polaris, and Canis are on ${version}; the Navis pin is published."
