#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
state_dir="${T3CODE_CHANNEL_STATE_DIR:-$HOME/.local/state/t3code-channel}"
source_repo="$state_dir/source"
state_file="$state_dir/state.json"
fork_repo="${T3CODE_CHANNEL_FORK_REPO:-skulldogged/t3code}"
fork_url="https://github.com/${fork_repo}.git"
upstream_url="${T3CODE_CHANNEL_UPSTREAM_URL:-https://github.com/pingdotgg/t3code.git}"
initial_sequence="${T3CODE_CHANNEL_INITIAL_SEQUENCE:-40}"

mkdir -p "$state_dir"
exec 9>"$state_dir/update.lock"
if ! flock -n 9; then
  printf '%s Another T3 Code channel update is already running.\n' "$(date --iso-8601=seconds)"
  exit 0
fi

log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    exit 1
  fi
}

for command_name in git gh node flock; do
  require_command "$command_name"
done

if [[ ! -d "$source_repo/.git" ]]; then
  log "Cloning the personal T3 Code fork."
  git clone "$fork_url" "$source_repo"
  git -C "$source_repo" remote add upstream "$upstream_url"
fi

if [[ -n "$(git -C "$source_repo" status --porcelain)" ]]; then
  log "The channel source checkout is dirty: $source_repo"
  exit 1
fi

if ! git -C "$source_repo" remote get-url upstream >/dev/null 2>&1; then
  git -C "$source_repo" remote add upstream "$upstream_url"
fi

log "Fetching the fork, upstream main, PR #5882, and tags."
git -C "$source_repo" fetch origin main --tags
git -C "$source_repo" fetch upstream \
  +refs/heads/main:refs/remotes/upstream/main \
  +refs/pull/5882/head:refs/remotes/upstream/pr-5882
git -C "$source_repo" checkout main
git -C "$source_repo" merge --ff-only origin/main

previous_pr_sha=""
previous_integration_sha=""
sequence="$initial_sequence"
if [[ -f "$state_file" ]]; then
  previous_pr_sha="$(node -e 'const s=require(process.argv[1]); process.stdout.write(s.prSha ?? "")' "$state_file")"
  previous_integration_sha="$(node -e 'const s=require(process.argv[1]); process.stdout.write(s.integrationSha ?? "")' "$state_file")"
  sequence="$(node -e 'const s=require(process.argv[1]); process.stdout.write(String(s.sequence ?? process.argv[2]))' "$state_file" "$initial_sequence")"
fi

pr_sha="$(git -C "$source_repo" rev-parse upstream/pr-5882)"
main_sha="$(git -C "$source_repo" rev-parse upstream/main)"
if [[ -n "$previous_pr_sha" && "$pr_sha" != "$previous_pr_sha" ]]; then
  log "PR #5882 changed from ${previous_pr_sha:0:12} to ${pr_sha:0:12}."
  log "A manual review is required before the channel can continue."
  exit 1
fi

if ! git -C "$source_repo" merge --no-edit upstream/main; then
  git -C "$source_repo" merge --abort >/dev/null 2>&1 || true
  log "Upstream main conflicts with the Pi integration. The running release was not changed."
  exit 1
fi

integration_sha="$(git -C "$source_repo" rev-parse HEAD)"
if [[ -n "$previous_integration_sha" && "$integration_sha" == "$previous_integration_sha" ]]; then
  log "No source changes since the last successful fleet release."
  exit 0
fi

next_sequence="$((sequence + 1))"
version="0.0.${next_sequence}-main${main_sha:0:8}.pi.${integration_sha:0:8}"
tag="pi-v${version}"

log "Publishing integration ${integration_sha:0:12} as ${version}."
if [[ "${T3CODE_CHANNEL_DRY_RUN:-0}" == "1" ]]; then
  log "Dry run complete; no branch, tag, release, or machine was changed."
  exit 0
fi
git -C "$source_repo" push origin main
if git -C "$source_repo" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
  tag_sha="$(git -C "$source_repo" rev-list -n 1 "$tag")"
  if [[ "$tag_sha" != "$integration_sha" ]]; then
    log "Existing tag $tag points at a different commit."
    exit 1
  fi
else
  git -C "$source_repo" tag -a "$tag" -m "T3 Code Pi ${version}" "$integration_sha"
fi
git -C "$source_repo" push origin "refs/tags/$tag"

log "Waiting for the Pi release workflow."
workflow_url=""
for attempt in $(seq 1 120); do
  runs_json="$(gh run list --repo "$fork_repo" --workflow "Pi release" --limit 30 \
    --json databaseId,headSha,status,conclusion,url)"
  run_line="$(node -e '
    let input = "";
    process.stdin.on("data", (chunk) => { input += chunk; });
    process.stdin.on("end", () => {
      const sha = process.argv[1];
      const run = JSON.parse(input).find((item) => item.headSha === sha);
      if (run) process.stdout.write([run.databaseId, run.status, run.conclusion ?? "", run.url].join("\t"));
    });
  ' "$integration_sha" <<<"$runs_json")"
  if [[ -z "$run_line" ]]; then
    sleep 15
    continue
  fi

  IFS=$'\t' read -r run_id run_status run_conclusion workflow_url <<<"$run_line"
  if [[ "$run_status" == "completed" ]]; then
    if [[ "$run_conclusion" != "success" ]]; then
      log "Release workflow failed: $workflow_url"
      exit 1
    fi
    break
  fi

  if (( attempt == 120 )); then
    log "Timed out waiting for release workflow: $workflow_url"
    exit 1
  fi
  sleep 30
done

log "Release workflow succeeded: $workflow_url"
"$script_dir/deploy.sh" "$version"

temporary_state="$state_file.new"
node -e '
  const fs = require("node:fs");
  const [output, version, sequence, mainSha, prSha, integrationSha, workflowUrl] = process.argv.slice(1);
  fs.writeFileSync(output, `${JSON.stringify({
    version,
    sequence: Number(sequence),
    mainSha,
    prSha,
    integrationSha,
    workflowUrl,
    updatedAt: new Date().toISOString(),
  }, null, 2)}\n`, { mode: 0o600 });
' "$temporary_state" "$version" "$next_sequence" "$main_sha" "$pr_sha" "$integration_sha" "$workflow_url"
mv "$temporary_state" "$state_file"
log "Fleet release ${version} is complete."
