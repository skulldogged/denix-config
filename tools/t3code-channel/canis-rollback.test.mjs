import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

for (const failure of ["snapshot", "bootstrap"]) {
  test(`Canis preserves the original database after ${failure} failure`, () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "t3-canis-rollback-"));
    try {
      const bin = path.join(root, "bin");
      const version = "0.0.41-nightly.20260909.1461.personal.1";
      const install = path.join(root, ".local/share/t3code");
      const database = path.join(install, "userdata/state.sqlite");
      const plist = path.join(root, "Library/LaunchAgents/codes.t3.server.plist");
      for (const dir of [bin, path.dirname(database), path.dirname(plist), path.join(install, version)]) fs.mkdirSync(dir, { recursive: true });
      const db = new DatabaseSync(database);
      db.exec("CREATE TABLE orchestration_v2_projection_runs(status TEXT); INSERT INTO orchestration_v2_projection_runs VALUES ('completed');");
      db.close();
      fs.writeFileSync(plist, "old launcher");
      fs.writeFileSync(path.join(install, version, ".install-complete"), `${version}\n`);
      const original = fs.readFileSync(database);
      const writeShim = (name, body) => fs.writeFileSync(path.join(bin, name), `#!/usr/bin/env bash\nset -euo pipefail\n${body}\n`, { mode: 0o755 });
      writeShim("sleep", "exit 0");
      writeShim("plistbuddy", `if [[ "$2" == Print* ]]; then echo old-entry; else echo new-launcher > "$3"; fi`);
      writeShim("cp", `if [[ "$FAILURE" == snapshot && "$1" == "$DATABASE" ]]; then exit 44; fi\nexec /bin/cp "$@"`);
      writeShim("launchctl", `echo "$*" >> "$TEST_LOG"
if [[ "$1" == bootstrap && "$FAILURE" == bootstrap && ! -e "$TEST_MARKER" ]]; then
  touch "$TEST_MARKER"
  echo changed-database > "$DATABASE"
  echo new-sidecar > "$DATABASE-wal"
  exit 45
fi
exit 0`);
      const script = fs.readFileSync(path.join(import.meta.dirname, "deploy.sh"), "utf8")
        .split("<<'CANIS'\n")[1].split("\nCANIS\n")[0]
        .replaceAll("$HOME", root)
        .replaceAll("/usr/libexec/PlistBuddy", path.join(bin, "plistbuddy"))
        .replaceAll("/opt/homebrew/opt/node@24/bin/node", process.execPath);
      const result = spawnSync("bash", ["-s", "--", version, "unused.tgz", path.join(import.meta.dirname, "check-idle.mjs")], {
        input: script, encoding: "utf8",
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, FAILURE: failure, DATABASE: database, TEST_LOG: path.join(root, "operations"), TEST_MARKER: path.join(root, "failed") },
      });
      assert.equal(result.status, 1, result.stderr);
      assert.deepEqual(fs.readFileSync(database), original);
      assert.equal(fs.readFileSync(plist, "utf8"), "old launcher");
      assert.equal(fs.existsSync(`${database}-wal`), false);
      assert.match(fs.readFileSync(path.join(root, "operations"), "utf8"), /bootstrap/);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
}
