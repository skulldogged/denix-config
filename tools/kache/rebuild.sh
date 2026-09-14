#!/usr/bin/env bash
set -euo pipefail
# Pass true only after the external ~/.aws/credentials [kache] profile is ready.
remoteEnabled=${1:-true}
case "$remoteEnabled" in true|false) ;; *) exit 2 ;; esac
nixpkgs=$(nix eval --raw --impure --expr '(builtins.getFlake "path:/home/marshall/nix-config").inputs.nixpkgs.outPath')
nix build --impure --file "$HOME/nix-config/tools/kache/default.nix" --arg pkgs "import $nixpkgs {}" --arg remoteEnabled "$remoteEnabled" --profile "$HOME/.local/state/nix/profiles/kache" --no-link
