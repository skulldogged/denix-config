#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
state_dir="${T3CODE_CHANNEL_STATE_DIR:-$HOME/.local/state/t3code-channel}"
source_repo="$state_dir/source"
state_file="$state_dir/state.json"
health_file="$state_dir/health.json"
fork_repo="${T3CODE_CHANNEL_FORK_REPO:-skulldogged/t3code}"
fork_url="https://github.com/${fork_repo}.git"
upstream_url="${T3CODE_CHANNEL_UPSTREAM_URL:-https://github.com/pingdotgg/t3code.git}"

mkdir -p "$state_dir"
exec 9>"$state_dir/update.lock"
if ! flock -n 9; then
  printf '%s Another T3 Code channel update is already running.\n' "$(date --iso-8601=seconds)"
  exit 0
fi

log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

main_sha=""
nightly_tag=""
origin_sha=""
integration_sha=""
workflow_url=""
current_stage="initializing"

write_health() {
  local status="$1"
  local incident_key="$2"
  local summary="$3"
  local temporary_health="$health_file.new"
  node -e '
    const fs = require("node:fs");
    const [output, status, incidentKey, summary, stage, originSha, mainSha, nightlyTag, integrationSha, workflowUrl] = process.argv.slice(1);
    fs.writeFileSync(output, `${JSON.stringify({
      status,
      incidentKey: incidentKey || null,
      summary,
      stage,
      originSha: originSha || null,
      mainSha: mainSha || null,
      nightlyTag: nightlyTag || null,
      integrationSha: integrationSha || null,
      workflowUrl: workflowUrl || null,
      checkedAt: new Date().toISOString(),
    }, null, 2)}\n`, { mode: 0o600 });
  ' "$temporary_health" "$status" "$incident_key" "$summary" "$current_stage" \
    "$origin_sha" "$main_sha" "$nightly_tag" "$integration_sha" "$workflow_url"
  mv "$temporary_health" "$health_file"
}

health_has_incident() {
  local incident_key="$1"
  [[ -f "$health_file" ]] && node -e '
    const fs = require("node:fs");
    const [path, expected] = process.argv.slice(1);
    try {
      const health = JSON.parse(fs.readFileSync(path, "utf8"));
      process.exit(health.status !== "healthy" && health.incidentKey === expected ? 0 : 1);
    } catch {
      process.exit(1);
    }
  ' "$health_file" "$incident_key"
}

record_unexpected_failure() {
  local exit_code="$?"
  trap - ERR
  write_health \
    "failed" \
    "unexpected:${current_stage}:${origin_sha:-unknown}:${main_sha:-unknown}:${nightly_tag:-unknown}" \
    "The T3 Code channel updater failed unexpectedly during ${current_stage}."
  exit "$exit_code"
}

write_release_state() {
  local deployment_status="$1"
  local temporary_state="$state_file.new"
  node -e '
    const fs = require("node:fs");
    const [output, version, mainSha, nightlyTag, integrationSha, workflowUrl, deploymentStatus] = process.argv.slice(1);
    fs.writeFileSync(output, `${JSON.stringify({
      version,
      mainSha,
      nightlyTag,
      integrationSha,
      workflowUrl,
      deploymentStatus,
      updatedAt: new Date().toISOString(),
    }, null, 2)}\n`, { mode: 0o600 });
  ' "$temporary_state" "$version" "$main_sha" "$nightly_tag" "$integration_sha" "$workflow_url" "$deployment_status"
  mv "$temporary_state" "$state_file"
}

mark_deployment_complete() {
  local temporary_state="$state_file.new"
  node -e '
    const fs = require("node:fs");
    const [input, output] = process.argv.slice(1);
    const state = JSON.parse(fs.readFileSync(input, "utf8"));
    fs.writeFileSync(output, `${JSON.stringify({
      ...state,
      deploymentStatus: "complete",
      updatedAt: new Date().toISOString(),
    }, null, 2)}\n`, { mode: 0o600 });
  ' "$state_file" "$temporary_state"
  mv "$temporary_state" "$state_file"
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

trap record_unexpected_failure ERR

if [[ ! -d "$source_repo/.git" ]]; then
  log "Cloning the personal T3 Code fork."
  git clone "$fork_url" "$source_repo"
  git -C "$source_repo" remote add upstream "$upstream_url"
fi

if [[ -n "$(git -C "$source_repo" status --porcelain)" ]]; then
  log "The channel source checkout is dirty: $source_repo"
  write_health "failed" "dirty-checkout" "The T3 Code channel source checkout is dirty."
  exit 1
fi

if ! git -C "$source_repo" remote get-url upstream >/dev/null 2>&1; then
  git -C "$source_repo" remote add upstream "$upstream_url"
fi

log "Fetching the fork and latest published official nightly."
nightly_tag="$(gh api repos/pingdotgg/t3code/releases --jq '[.[] | select(.draft == false and (.tag_name | contains("-nightly.")))] | sort_by(.published_at) | last | .tag_name')"
if [[ ! "$nightly_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\.[0-9]+$ ]]; then
  log "No valid published official nightly was found."
  exit 1
fi
git -C "$source_repo" fetch origin main --tags
git -C "$source_repo" fetch upstream "refs/tags/$nightly_tag:refs/tags/$nightly_tag"
git -C "$source_repo" checkout main
git -C "$source_repo" merge --ff-only origin/main
git -C "$source_repo" config rerere.enabled true
git -C "$source_repo" config rerere.autoupdate true

previous_integration_sha=""
previous_version=""
previous_deployment_status="complete"
if [[ -f "$state_file" ]]; then
  previous_integration_sha="$(node -e 'const s=require(process.argv[1]); process.stdout.write(s.integrationSha ?? "")' "$state_file")"
  previous_version="$(node -e 'const s=require(process.argv[1]); process.stdout.write(s.version ?? "")' "$state_file")"
  previous_deployment_status="$(node -e 'const s=require(process.argv[1]); process.stdout.write(s.deploymentStatus ?? "complete")' "$state_file")"
fi

if [[ "$previous_deployment_status" != "complete" && "$previous_deployment_status" != "pending" ]]; then
  log "The channel state contains an invalid deployment status: $previous_deployment_status"
  exit 1
fi

main_sha="$(git -C "$source_repo" rev-parse "$nightly_tag^{commit}")"
origin_sha="$(git -C "$source_repo" rev-parse origin/main)"

merge_incident_key="merge-conflict:${origin_sha}:${main_sha}"
if health_has_incident "$merge_incident_key"; then
  log "The same upstream/personal merge is still blocked; suppressing a repeated failed run."
  exit 0
fi

current_stage="waiting for official nightly"
# Main was already integrated through this commit before switching channels.
# Publish only once an official nightly contains the existing upstream base.
nightly_floor="6365919f2e5bcfb4fa4020b95e19af26ae40979f"
if ! git -C "$source_repo" merge-base --is-ancestor "$nightly_floor" "$main_sha"; then
  log "Waiting for an official nightly containing the already-integrated upstream commits."
  write_health "updating" "" "Waiting for the next official nightly to include the current upstream base."
  exit 0
fi
current_stage="merging official nightly"
write_health "updating" "" "Checking upstream T3 Code changes."
if ! git -C "$source_repo" merge --no-edit "$nightly_tag"; then
  unresolved_files="$(git -C "$source_repo" diff --name-only --diff-filter=U)"
  if [[ -z "$unresolved_files" ]] && git -C "$source_repo" rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
    log "Reusing recorded conflict resolutions for this upstream merge."
    git -C "$source_repo" commit --no-edit
  else
    git -C "$source_repo" merge --abort >/dev/null 2>&1 || true
    log "Official nightly conflicts with the personal changes. The running release was not changed."
    if [[ -n "$unresolved_files" ]]; then
      log "Conflicted files: $(tr '\n' ' ' <<<"$unresolved_files")"
    fi
    write_health "blocked" "$merge_incident_key" "Official nightly conflicts with the personal changes and needs a manual resolution."
    exit 1
  fi
fi

integration_sha="$(git -C "$source_repo" rev-parse HEAD)"
if [[ -n "$previous_integration_sha" && "$integration_sha" == "$previous_integration_sha" ]]; then
  if [[ "$previous_deployment_status" == "pending" ]]; then
    if [[ -z "$previous_version" ]]; then
      log "The pending deployment does not record a release version."
      exit 1
    fi
    log "Retrying the incomplete fleet deployment for ${previous_version}."
    "$script_dir/deploy.sh" "$previous_version"
    mark_deployment_complete
    current_stage="complete"
    write_health "healthy" "" "The T3 Code release channel is healthy."
    log "Fleet release ${previous_version} is complete."
    exit 0
  fi
  current_stage="complete"
  write_health "healthy" "" "The T3 Code release channel is healthy and already current."
  log "No source changes since the last successful fleet release."
  exit 0
fi

version="$(node "$script_dir/release-version.mjs" "$nightly_tag" "$(git -C "$source_repo" tag --list 'personal-v*')")"

log "Publishing integration ${integration_sha:0:12} as ${version}."
if [[ "${T3CODE_CHANNEL_DRY_RUN:-0}" == "1" ]]; then
  current_stage="complete"
  write_health "healthy" "" "The T3 Code release channel dry run completed successfully."
  log "Dry run complete; no branch, tag, release, or machine was changed."
  exit 0
fi
current_stage="publishing integration branch"
git -C "$source_repo" push origin main
gh workflow run "personal-release.yml" --repo "$fork_repo" --ref main --field "version=$version"

log "Waiting for the personal release workflow."
current_stage="waiting for release workflow"
for attempt in $(seq 1 120); do
  runs_json="$(gh run list --repo "$fork_repo" --workflow "personal-release.yml" --limit 30 \
    --json databaseId,event,headSha,status,conclusion,url)"
  run_line="$(node -e '
    let input = "";
    process.stdin.on("data", (chunk) => { input += chunk; });
    process.stdin.on("end", () => {
      const sha = process.argv[1];
      const run = JSON.parse(input).find(
        (item) => item.headSha === sha && item.event === "workflow_dispatch",
      );
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
      write_health "failed" "workflow:${integration_sha}:${run_id}" "The T3 Code release workflow failed."
      exit 1
    fi
    break
  fi

  if (( attempt == 120 )); then
    log "Timed out waiting for release workflow: $workflow_url"
    write_health "failed" "workflow-timeout:${integration_sha}" "The T3 Code release workflow timed out."
    exit 1
  fi
  sleep 30
done

log "Release workflow succeeded: $workflow_url"
write_release_state "pending"
current_stage="deploying fleet"
"$script_dir/deploy.sh" "$version"
mark_deployment_complete
current_stage="complete"
write_health "healthy" "" "The T3 Code release channel is healthy."
log "Fleet release ${version} is complete."
