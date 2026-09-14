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
overlay_manifest="${T3CODE_CHANNEL_OVERLAYS_FILE:-$script_dir/overlays.json}"
deploy_script="${T3CODE_CHANNEL_DEPLOY_SCRIPT:-$script_dir/deploy.sh}"

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
overlay_shas_json="[]"
workflow_url=""
current_stage="initializing"
integration_active=0

write_health() {
  local status="$1"
  local incident_key="$2"
  local summary="$3"
  local temporary_health="$health_file.new"
  node -e '
    const fs = require("node:fs");
    const [output, status, incidentKey, summary, stage, originSha, mainSha, nightlyTag, integrationSha, workflowUrl, overlays] = process.argv.slice(1);
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
      overlays: JSON.parse(overlays || "[]"),
      checkedAt: new Date().toISOString(),
    }, null, 2)}\n`, { mode: 0o600 });
  ' "$temporary_health" "$status" "$incident_key" "$summary" "$current_stage" \
    "$origin_sha" "$main_sha" "$nightly_tag" "$integration_sha" "$workflow_url" "$overlay_shas_json"
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
  if [[ "$integration_active" == "1" ]]; then
    if ! restore_integration_base; then
      log "Could not restore the source checkout after the upstream merge conflict."
      exit 1
    fi
    if ! git -C "$source_repo" reset --hard "$integration_base_sha" >/dev/null 2>&1; then
      log "Could not restore the source checkout after an integration failure."
      exit 1
    fi
  fi
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
    const [output, version, mainSha, nightlyTag, integrationSha, workflowUrl, deploymentStatus, overlays] = process.argv.slice(1);
    fs.writeFileSync(output, `${JSON.stringify({
      version,
      mainSha,
      nightlyTag,
      integrationSha,
      workflowUrl,
      overlays: JSON.parse(overlays),
      deploymentStatus,
      updatedAt: new Date().toISOString(),
    }, null, 2)}\n`, { mode: 0o600 });
  ' "$temporary_state" "$version" "$main_sha" "$nightly_tag" "$integration_sha" "$workflow_url" "$deployment_status" "$overlay_shas_json"
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

run_deployment() {
  local deployment_status
  set +e
  "$deploy_script" "$1"
  deployment_status=$?
  set -e
  if (( deployment_status == 75 )); then
    current_stage="deploying fleet"
    write_health "updating" "deployment-busy:$1" "Waiting for active turns to finish before deploying the pending release."
    log "Fleet deployment deferred because active turns are still running."
    exit 0
  fi
  return "$deployment_status"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    exit 1
  fi
}

for command_name in git gh node flock sha256sum; do
  require_command "$command_name"
done

if [[ ! -f "$overlay_manifest" ]] || ! node --input-type=module -e 'import(process.argv[1]).then(({readOverlayManifest}) => readOverlayManifest(process.argv[2]))' "$script_dir/source-selection.mjs" "$overlay_manifest"; then
  log "The overlay manifest is missing or invalid: $overlay_manifest"
  write_health "failed" "invalid-overlay-manifest" "The configured overlay manifest is missing or empty."
  exit 1
fi

trap record_unexpected_failure ERR

# A published release is deployable independently of newer source changes.
# Retry it before fetching or merging, which may need manual intervention.
if [[ -f "$state_file" ]] && [[ "$(node -e 'const s=require(process.argv[1]); process.stdout.write(s.deploymentStatus ?? "")' "$state_file")" == "pending" ]]; then
  version="$(node -e 'const s=require(process.argv[1]); process.stdout.write(s.version ?? "")' "$state_file")"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+$ ]]; then
    log "The pending deployment does not record a valid release version."
    exit 1
  fi
  integration_sha="$(node -e 'process.stdout.write(require(process.argv[1]).integrationSha ?? "")' "$state_file")"
  main_sha="$(node -e 'process.stdout.write(require(process.argv[1]).mainSha ?? "")' "$state_file")"
  nightly_tag="$(node -e 'process.stdout.write(require(process.argv[1]).nightlyTag ?? "")' "$state_file")"
  workflow_url="$(node -e 'process.stdout.write(require(process.argv[1]).workflowUrl ?? "")' "$state_file")"
  overlay_shas_json="$(node -e 'process.stdout.write(JSON.stringify(require(process.argv[1]).overlays ?? []))' "$state_file")"
  current_stage="deploying fleet"
  log "Retrying the incomplete fleet deployment for ${version}."
  run_deployment "$version"
  mark_deployment_complete
  current_stage="complete"
  write_health "healthy" "" "The pending T3 Code release was deployed successfully."
  exit 0
fi

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

log "Fetching the fork, upstream main, and configured pull-request overlays."
nightly_tag="$(gh api repos/pingdotgg/t3code/releases --jq '[.[] | select(.draft == false and (.tag_name | contains("-nightly.")))] | sort_by(.published_at) | last | .tag_name')"
if [[ ! "$nightly_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\.[0-9]+$ ]]; then
  log "No valid published official nightly was found."
  exit 1
fi
git -C "$source_repo" fetch origin main --tags
git -C "$source_repo" fetch upstream "+refs/heads/main:refs/remotes/upstream/main"
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

main_sha="$(git -C "$source_repo" rev-parse refs/remotes/upstream/main^{commit})"
origin_sha="$(git -C "$source_repo" rev-parse origin/main)"
integration_base_sha="$(git -C "$source_repo" rev-parse HEAD)"

restore_integration_base() {
  git -C "$source_repo" merge --abort >/dev/null 2>&1 || true
  git -C "$source_repo" reset --hard "$integration_base_sha" >/dev/null 2>&1 || return 1
}

current_stage="fetching pull-request overlays"
overlay_shas_json="[]"
while IFS=$'\t' read -r overlay_repo overlay_number overlay_label; do
  [[ -z "$overlay_repo" ]] && continue
  overlay_ref="refs/remotes/overlay/${overlay_repo//\//-}-$overlay_number"
  git -C "$source_repo" fetch "https://github.com/$overlay_repo.git" "+refs/pull/$overlay_number/head:$overlay_ref"
  overlay_sha="$(git -C "$source_repo" rev-parse "$overlay_ref")"
  previous_overlay_sha="$(node -e 'const s=require(process.argv[1]); const [repo,n]=process.argv.slice(2); process.stdout.write(s.overlays?.find(x=>x.repository===repo&&String(x.number)===n)?.sha??"")' "$state_file" "$overlay_repo" "$overlay_number" 2>/dev/null || true)"
  if [[ -n "$previous_overlay_sha" && "$previous_overlay_sha" != "$overlay_sha" ]] \
    && ! git -C "$source_repo" merge-base --is-ancestor "$previous_overlay_sha" "$overlay_sha" \
    && ! git -C "$source_repo" merge-base --is-ancestor "$overlay_sha" "$origin_sha"; then
    log "Overlay $overlay_repo#$overlay_number was rewritten; manual integration is required."
    write_health "blocked" "overlay-rewrite:$overlay_repo:$overlay_number:$overlay_sha" "A configured pull-request overlay was rewritten and needs manual integration."
    exit 1
  fi
  overlay_shas_json="$(node -e 'const [json,repo,n,label,sha]=process.argv.slice(1); const a=JSON.parse(json); a.push({repository:repo,number:Number(n),label,sha}); process.stdout.write(JSON.stringify(a))' "$overlay_shas_json" "$overlay_repo" "$overlay_number" "$overlay_label" "$overlay_sha")"
done < <(node -e 'const fs=require("node:fs"); for(const x of JSON.parse(fs.readFileSync(process.argv[1],"utf8"))) console.log([x.repository,x.number,x.label??`PR #${x.number}`].join("\t"))' "$overlay_manifest")

source_digest="$(printf '%s\n%s\n' "$main_sha" "$overlay_shas_json" | sha256sum | cut -d' ' -f1)"
merge_incident_key="merge-conflict:${origin_sha}:${source_digest}"
if health_has_incident "$merge_incident_key"; then
  log "The same source merge is still blocked; suppressing a repeated failed run."
  exit 0
fi

current_stage="merging upstream main"
integration_active=1
write_health "updating" "" "Checking upstream main and configured pull-request overlays."
if ! git -C "$source_repo" merge --no-edit "$main_sha"; then
  unresolved_files="$(git -C "$source_repo" diff --name-only --diff-filter=U)"
  if [[ -z "$unresolved_files" ]] && git -C "$source_repo" rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
    log "Reusing recorded conflict resolutions for this upstream merge."
    git -C "$source_repo" commit --no-edit
  else
    if ! restore_integration_base; then
      log "Could not restore the source checkout after the upstream merge conflict."
      exit 1
    fi
    log "Upstream main conflicts with the personal changes. The running release was not changed."
    if [[ -n "$unresolved_files" ]]; then
      log "Conflicted files: $(tr '\n' ' ' <<<"$unresolved_files")"
    fi
    write_health "blocked" "$merge_incident_key" "Upstream main conflicts with the personal changes and needs a manual resolution."
    exit 1
  fi
fi

while IFS=$'\t' read -r overlay_repo overlay_number overlay_label overlay_sha; do
  [[ -z "$overlay_repo" ]] && continue
  if ! git -C "$source_repo" merge --no-edit "$overlay_sha"; then
    unresolved_files="$(git -C "$source_repo" diff --name-only --diff-filter=U)"
    if [[ -z "$unresolved_files" ]] && git -C "$source_repo" rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
      log "Reusing recorded conflict resolutions for overlay $overlay_repo#$overlay_number."
      git -C "$source_repo" commit --no-edit
    else
      if ! restore_integration_base; then
        log "Could not restore the source checkout after the overlay merge conflict."
        exit 1
      fi
      log "Overlay $overlay_repo#$overlay_number conflicts with the personal changes. Manual integration is required."
      write_health "blocked" "$merge_incident_key" "A configured pull-request overlay conflicts and needs manual integration."
      exit 1
    fi
  fi
done < <(node -e 'for(const x of JSON.parse(process.argv[1])) console.log([x.repository,x.number,x.label??`PR #${x.number}`,x.sha].join("\t"))' "$overlay_shas_json")

integration_sha="$(git -C "$source_repo" rev-parse HEAD)"
if [[ -n "$previous_integration_sha" && "$integration_sha" == "$previous_integration_sha" ]]; then
  if [[ "$previous_deployment_status" == "pending" ]]; then
    if [[ -z "$previous_version" ]]; then
      log "The pending deployment does not record a release version."
      exit 1
    fi
    log "Retrying the incomplete fleet deployment for ${previous_version}."
    run_deployment "$previous_version"
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
workflow_inputs_file="$state_dir/workflow-inputs.json"
node -e '
  const fs = require("node:fs");
  const [output, version, expectedSha, mainSha, overlays] = process.argv.slice(1);
  fs.writeFileSync(output, `${JSON.stringify({version, expected_sha: expectedSha, source_manifest: JSON.stringify({mainSha, overlays: JSON.parse(overlays)})})}\n`, {mode: 0o600});
' "$workflow_inputs_file" "$version" "$integration_sha" "$main_sha" "$overlay_shas_json"

log "Publishing integration ${integration_sha:0:12} as ${version}."
if [[ "${T3CODE_CHANNEL_DRY_RUN:-0}" == "1" ]]; then
  current_stage="complete"
  write_health "healthy" "" "The T3 Code release channel dry run completed successfully."
  log "Dry run complete; no remote branch, tag, release, or machine was changed."
  exit 0
fi
current_stage="publishing integration branch"
git -C "$source_repo" push origin main
integration_active=0
gh workflow run "personal-release.yml" --repo "$fork_repo" --ref main --json < "$workflow_inputs_file"

log "Waiting for the personal release workflow."
current_stage="waiting for release workflow"
workflow_completed=0
workflow_attempts="${T3CODE_CHANNEL_WORKFLOW_ATTEMPTS:-120}"
workflow_sleep_seconds="${T3CODE_CHANNEL_WORKFLOW_SLEEP_SECONDS:-30}"
for attempt in $(seq 1 "$workflow_attempts"); do
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
      if (run) process.stdout.write([run.databaseId, run.status, run.conclusion ?? "", run.url].join("|"));
    });
  ' "$integration_sha" <<<"$runs_json")"
  if [[ -z "$run_line" ]]; then
    sleep "$workflow_sleep_seconds"
    continue
  fi

  IFS='|' read -r run_id run_status run_conclusion workflow_url <<<"$run_line"
  if [[ "$run_status" == "completed" ]]; then
    if [[ "$run_conclusion" != "success" ]]; then
      log "Release workflow failed: $workflow_url"
      write_health "failed" "workflow:${integration_sha}:${run_id}" "The T3 Code release workflow failed."
      exit 1
    fi
    workflow_completed=1
    break
  fi
  sleep "$workflow_sleep_seconds"
done

if [[ "$workflow_completed" != "1" ]]; then
  log "Timed out waiting for release workflow: ${workflow_url:-not found}"
  write_health "failed" "workflow-timeout:${integration_sha}" "The T3 Code release workflow did not appear or finish in time."
  exit 1
fi

log "Release workflow succeeded: $workflow_url"
write_release_state "pending"
current_stage="deploying fleet"
run_deployment "$version"
mark_deployment_complete
current_stage="complete"
write_health "healthy" "" "The T3 Code release channel is healthy."
log "Fleet release ${version} is complete."
