import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { activeTurnCount, checkIdle } from "./check-idle.mjs";

const temporaryDatabase = (schema, rows = []) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "t3-idle-"));
  const file = path.join(directory, "state.sqlite");
  const database = new DatabaseSync(file);
  database.exec(schema);
  const table = schema.includes("orchestration_v2_projection_runs")
    ? "orchestration_v2_projection_runs"
    : "projection_runs";
  for (const [status] of rows) database.prepare(`INSERT INTO ${table}(status) VALUES (?)`).run(status);
  database.close();
  return { file, directory };
};

test("reports idle for an empty V2 database", () => {
  const { file, directory } = temporaryDatabase("CREATE TABLE orchestration_v2_projection_runs (run_id TEXT, thread_id TEXT, ordinal INTEGER, provider TEXT, status TEXT NOT NULL, requested_at TEXT, completed_at TEXT, payload_json TEXT)");
  assert.deepEqual(checkIdle(file), { idle: true, count: 0 });
  fs.rmSync(directory, { recursive: true, force: true });
});

test("counts nonterminal V2 runs", () => {
  const { file, directory } = temporaryDatabase(
    "CREATE TABLE orchestration_v2_projection_runs (run_id TEXT, thread_id TEXT, ordinal INTEGER, provider TEXT, status TEXT NOT NULL, requested_at TEXT, completed_at TEXT, payload_json TEXT)",
    [["running"], ["waiting"], ["completed"], ["failed"]],
  );
  assert.equal(activeTurnCount(file), 2);
  fs.rmSync(directory, { recursive: true, force: true });
});

test("does not treat parked queued V2 runs as active", () => {
  const { file, directory } = temporaryDatabase(
    "CREATE TABLE orchestration_v2_projection_runs (run_id TEXT, thread_id TEXT, ordinal INTEGER, provider TEXT, status TEXT NOT NULL, requested_at TEXT, completed_at TEXT, payload_json TEXT)",
    [["queued"]],
  );
  assert.deepEqual(checkIdle(file), { idle: true, count: 0 });
  fs.rmSync(directory, { recursive: true, force: true });
});

test("falls back to V1 sessions when V2 has no populated projection", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "t3-idle-"));
  const file = path.join(directory, "state.sqlite");
  const database = new DatabaseSync(file);
  database.exec("CREATE TABLE orchestration_v2_projection_runs (run_id TEXT, thread_id TEXT, ordinal INTEGER, provider TEXT, status TEXT NOT NULL, requested_at TEXT, completed_at TEXT, payload_json TEXT); CREATE TABLE projection_thread_sessions (status TEXT NOT NULL);");
  database.prepare("INSERT INTO projection_thread_sessions(status) VALUES (?)").run("starting");
  database.prepare("INSERT INTO projection_thread_sessions(status) VALUES (?)").run("completed");
  database.close();
  assert.equal(activeTurnCount(file), 1);
  fs.rmSync(directory, { recursive: true, force: true });
});

test("fails closed for an unavailable database", () => {
  assert.throws(() => checkIdle("/does/not/exist/state.sqlite"), /could not inspect SQLite/);
});

test("fails closed for an unknown database schema", () => {
  const { file, directory } = temporaryDatabase("CREATE TABLE unrelated (value TEXT)");
  assert.throws(() => checkIdle(file), /could not identify a supported activity projection/);
  fs.rmSync(directory, { recursive: true, force: true });
});
