import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const switchScript = path.join(import.meta.dirname, "switch-service.mjs");

test("defers a busy switch before mutating state or invoking systemctl", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "t3-switch-"));
  const runtime = path.join(root, "runtime");
  const versions = path.join(runtime, "versions", "1.0.1");
  const userdata = path.join(root, "userdata");
  fs.mkdirSync(versions, { recursive: true });
  fs.mkdirSync(userdata, { recursive: true });
  fs.writeFileSync(path.join(runtime, "service-state.json"), '{"protocol":2,"activeVersion":"1.0.0"}\n');
  fs.writeFileSync(path.join(versions, ".install-complete"), "1.0.1\n");
  const database = new DatabaseSync(path.join(userdata, "state.sqlite"));
  database.exec("CREATE TABLE orchestration_v2_projection_runs (run_id TEXT, thread_id TEXT, ordinal INTEGER, provider TEXT, status TEXT NOT NULL, requested_at TEXT, completed_at TEXT, payload_json TEXT)");
  database.prepare("INSERT INTO orchestration_v2_projection_runs(status) VALUES (?)").run("running");
  database.close();
  const bin = path.join(root, "bin");
  const calls = path.join(root, "systemctl.calls");
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, "systemctl"), `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> ${JSON.stringify(calls)}\nexit 0\n`);
  fs.chmodSync(path.join(bin, "systemctl"), 0o755);
  const result = spawnSync(process.execPath, [switchScript, root, "1.0.0", "1.0.1"], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
  });
  assert.equal(result.status, 75, result.stderr);
  assert.equal(fs.readFileSync(path.join(runtime, "service-state.json"), "utf8"), '{"protocol":2,"activeVersion":"1.0.0"}\n');
  assert.equal(fs.existsSync(path.join(runtime, "service-state.json.before-1.0.1.json")), false);
  assert.equal(fs.existsSync(calls), false);
  fs.rmSync(root, { recursive: true, force: true });
});
