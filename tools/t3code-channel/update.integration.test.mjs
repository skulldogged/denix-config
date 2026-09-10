import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const updater = path.join(import.meta.dirname, "update.sh");

function git(cwd, ...args) {
  return execFileSync("/usr/bin/git", args, { cwd, encoding: "utf8" }).trim();
}

function makeRepo(root, name) {
  const dir = path.join(root, name);
  fs.mkdirSync(dir);
  git(dir, "init", "--bare", "--initial-branch=main");
  return dir;
}

function makeWorld({ conflict = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "t3-channel-update-"));
  const upstream = makeRepo(root, "upstream.git");
  const fork = makeRepo(root, "fork.git");
  const overlay = makeRepo(root, "overlay.git");
  const work = path.join(root, "work");
  fs.mkdirSync(work);
  git(work, "init", "--initial-branch=main");
  git(work, "config", "user.email", "test@example.com");
  git(work, "config", "user.name", "Test");
  fs.writeFileSync(path.join(work, "source.txt"), "base\n");
  git(work, "add", "source.txt");
  git(work, "commit", "-m", "base");
  git(work, "remote", "add", "upstream", upstream);
  git(work, "push", "upstream", "main");
  git(work, "remote", "add", "fork", fork);
  if (conflict) {
    git(work, "checkout", "-b", "upstream-change");
    fs.writeFileSync(path.join(work, "source.txt"), "upstream\n");
    git(work, "commit", "-am", "upstream");
    git(work, "push", "upstream", "HEAD:main");
    git(work, "checkout", "main");
    fs.writeFileSync(path.join(work, "source.txt"), "personal\n");
    git(work, "commit", "-am", "personal");
    git(work, "push", "fork", "main");
  } else {
    git(work, "push", "fork", "main");
    fs.writeFileSync(path.join(work, "source.txt"), "upstream\n");
    git(work, "commit", "-am", "upstream");
    git(work, "push", "upstream", "HEAD:main");
  }

  git(work, "clone", upstream, path.join(root, "overlay-work"));
  const overlayWork = path.join(root, "overlay-work");
  git(overlayWork, "config", "user.email", "test@example.com");
  git(overlayWork, "config", "user.name", "Test");
  fs.writeFileSync(path.join(overlayWork, "overlay.txt"), "overlay\n");
  git(overlayWork, "add", "overlay.txt");
  git(overlayWork, "commit", "-m", "overlay");
  const overlaySha = git(overlayWork, "rev-parse", "HEAD");
  git(overlayWork, "push", overlay, `HEAD:refs/pull/2829/head`);
  return { root, upstream, fork, overlay, overlaySha };
}

function installShims(world, root) {
  const bin = path.join(root, "bin");
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, "git"), `#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    https://github.com/test/fork.git) arg="$FORK_REPO" ;;
    https://github.com/pingdotgg/t3code.git) arg="$UPSTREAM_REPO" ;;
    https://github.com/test/overlay.git) arg="$OVERLAY_REPO" ;;
  esac
  args+=("$arg")
done
if [[ "\${FAIL_OVERLAY_FETCH:-0}" == 1 && " \${args[*]} " == *"refs/pull/2829/head"* ]]; then exit 42; fi
exec /usr/bin/git "\${args[@]}"
`);
  fs.chmodSync(path.join(bin, "git"), 0o755);
  fs.writeFileSync(path.join(bin, "gh"), `#!/usr/bin/env bash
set -euo pipefail
if [[ " \$* " == *" api repos/pingdotgg/t3code/releases "* ]]; then
  printf '%s\\n' 'v0.0.39-nightly.20260905.1289'
  exit 0
fi
exit 0
`);
  fs.chmodSync(path.join(bin, "gh"), 0o755);
  return { ...process.env, PATH: `${bin}:${process.env.PATH}`, FORK_REPO: world.fork, UPSTREAM_REPO: world.upstream, OVERLAY_REPO: world.overlay };
}

function run(world, env, extra = {}, dryRun = true) {
  return execFileSync(updater, [], {
    cwd: path.dirname(updater),
    env: { ...env, T3CODE_CHANNEL_DRY_RUN: dryRun ? "1" : "0", ...extra },
    encoding: "utf8",
    stdio: "pipe",
  });
}

function manifest(root) {
  const file = path.join(root, "overlays.json");
  fs.writeFileSync(file, JSON.stringify([{ repository: "test/overlay", number: 2829, label: "V2" }]));
  return file;
}

test("refreshes and merges main plus an advanced PR when main is unchanged", () => {
  const world = makeWorld();
  const state = path.join(world.root, "state");
  const env = installShims(world, world.root);
  run(world, env, { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: manifest(world.root), T3CODE_CHANNEL_FORK_REPO: "test/fork" });
  assert.equal(git(path.join(state, "source"), "rev-parse", "HEAD"), world.overlaySha);
  assert.equal(JSON.parse(fs.readFileSync(path.join(state, "health.json"), "utf8")).overlays[0].sha, world.overlaySha);
});

test("blocks a rewritten PR head after forced refresh and leaves HEAD clean", () => {
  const world = makeWorld();
  const state = path.join(world.root, "state");
  const env = installShims(world, world.root);
  const overlayFile = manifest(world.root);
  run(world, env, { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: overlayFile, T3CODE_CHANNEL_FORK_REPO: "test/fork" });
  const source = path.join(state, "source");
  const base = git(source, "rev-parse", "HEAD");
  const replacement = path.join(world.root, "replacement");
  git(world.root, "clone", world.upstream, replacement);
  git(replacement, "config", "user.email", "test@example.com");
  git(replacement, "config", "user.name", "Test");
  fs.writeFileSync(path.join(replacement, "rewritten.txt"), "rewritten\n");
  git(replacement, "add", "rewritten.txt");
  git(replacement, "commit", "-m", "rewritten");
  git(replacement, "push", world.overlay, "HEAD:refs/pull/2829/head", "--force");
  const oldState = JSON.parse(fs.readFileSync(path.join(state, "health.json"), "utf8"));
  fs.writeFileSync(path.join(state, "state.json"), JSON.stringify({ integrationSha: base, overlays: [{ repository: "test/overlay", number: 2829, sha: world.overlaySha }], deploymentStatus: "complete" }));
  assert.throws(() => run(world, env, { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: overlayFile, T3CODE_CHANNEL_FORK_REPO: "test/fork" }));
  assert.equal(git(source, "rev-parse", "HEAD"), base);
  assert.equal(JSON.parse(fs.readFileSync(path.join(state, "health.json"), "utf8")).status, "blocked");
  void oldState;
});

test("leaves the checkout clean when an overlay fetch fails", () => {
  const world = makeWorld();
  const state = path.join(world.root, "state");
  const env = installShims(world, world.root);
  const overlayFile = manifest(world.root);
  run(world, env, { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: overlayFile, T3CODE_CHANNEL_FORK_REPO: "test/fork" });
  const source = path.join(state, "source");
  const base = git(source, "rev-parse", "HEAD");
  fs.rmSync(path.join(state, "source"), { recursive: true, force: true });
  fs.rmSync(state, { recursive: true, force: true });
  env.FAIL_OVERLAY_FETCH = "1";
  assert.throws(() => run(world, env, { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: overlayFile, T3CODE_CHANNEL_FORK_REPO: "test/fork" }));
  assert.equal(git(path.join(state, "source"), "status", "--porcelain"), "");
  assert.notEqual(git(path.join(state, "source"), "rev-parse", "HEAD"), "");
  void base;
});

test("aborts a main merge conflict without publishing a partial merge", () => {
  const world = makeWorld({ conflict: true });
  const state = path.join(world.root, "state");
  const env = installShims(world, world.root);
  const overlayFile = manifest(world.root);
  assert.throws(() => run(world, env, { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: overlayFile, T3CODE_CHANNEL_FORK_REPO: "test/fork" }));
  const source = path.join(state, "source");
  assert.equal(git(source, "status", "--porcelain"), "");
  assert.equal(git(source, "rev-parse", "HEAD"), git(world.root, "--git-dir", world.fork, "rev-parse", "main"));
});

test("suppresses publication when the complete source selection is unchanged", () => {
  const world = makeWorld();
  const state = path.join(world.root, "state");
  const env = installShims(world, world.root);
  const overlayFile = manifest(world.root);
  const options = { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: overlayFile, T3CODE_CHANNEL_FORK_REPO: "test/fork" };
  run(world, env, options);
  const source = path.join(state, "source");
  const integrationSha = git(source, "rev-parse", "HEAD");
  fs.writeFileSync(path.join(state, "state.json"), JSON.stringify({ integrationSha, deploymentStatus: "complete", overlays: [{ repository: "test/overlay", number: 2829, sha: world.overlaySha }] }));
  const output = run(world, env, options);
  assert.match(output, /No source changes/);
  assert.equal(JSON.parse(fs.readFileSync(path.join(state, "health.json"), "utf8")).status, "healthy");
  assert.equal(git(source, "rev-parse", "HEAD"), integrationSha);
});

test("does not advance release state when the workflow never appears", () => {
  const world = makeWorld();
  const state = path.join(world.root, "state");
  const env = installShims(world, world.root);
  const options = { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: manifest(world.root), T3CODE_CHANNEL_FORK_REPO: "test/fork", T3CODE_CHANNEL_WORKFLOW_ATTEMPTS: "2" };
  assert.throws(() => run(world, env, options, false));
  const saved = JSON.parse(fs.readFileSync(path.join(state, "health.json"), "utf8"));
  assert.equal(saved.status, "failed");
  assert.equal(fs.existsSync(path.join(state, "state.json")), false);
});

test("keeps a pending release when deployment is deferred for active turns", () => {
  const world = makeWorld();
  const state = path.join(world.root, "state");
  const env = installShims(world, world.root);
  const overlayFile = manifest(world.root);
  const options = { T3CODE_CHANNEL_STATE_DIR: state, T3CODE_CHANNEL_OVERLAYS_FILE: overlayFile, T3CODE_CHANNEL_FORK_REPO: "test/fork" };
  run(world, env, options);
  const source = path.join(state, "source");
  const integrationSha = git(source, "rev-parse", "HEAD");
  const deployment = path.join(world.root, "defer-deploy.sh");
  fs.writeFileSync(deployment, "#!/usr/bin/env bash\nexit 75\n");
  fs.chmodSync(deployment, 0o755);
  fs.writeFileSync(path.join(state, "state.json"), JSON.stringify({
    integrationSha,
    version: "0.0.39-nightly.20260905.1289.personal.1",
    deploymentStatus: "pending",
    overlays: [{ repository: "test/overlay", number: 2829, sha: world.overlaySha }],
  }));
  const output = run(world, env, { ...options, T3CODE_CHANNEL_DEPLOY_SCRIPT: deployment });
  assert.match(output, /deferred because active turns/);
  assert.equal(JSON.parse(fs.readFileSync(path.join(state, "state.json"), "utf8")).deploymentStatus, "pending");
  assert.equal(JSON.parse(fs.readFileSync(path.join(state, "health.json"), "utf8")).status, "updating");
  assert.match(JSON.parse(fs.readFileSync(path.join(state, "health.json"), "utf8")).summary, /active turns/);
});
