import { DatabaseSync } from "node:sqlite";

export const BUSY_EXIT_CODE = 75;

// Queued rows are durable follow-ups without an active provider attempt and
// do not keep the service busy. The active states are the provider lifecycle.
const V2_STATUSES = ["preparing", "starting", "running", "waiting"];
const V1_STATUSES = ["starting", "running"];
const V2_TABLE = "orchestration_v2_projection_runs";

const placeholders = (values) => values.map(() => "?").join(", ");

function tableExists(database, table) {
  return Boolean(database.prepare(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
  ).get(table));
}

function countStatuses(database, table, statuses) {
  return Number(database.prepare(
    `SELECT COUNT(*) AS count FROM ${table} WHERE status IN (${placeholders(statuses)})`,
  ).get(...statuses).count);
}

export function activeTurnCount(dbPath) {
  let database;
  try {
    database = new DatabaseSync(dbPath, { readOnly: true });
    let count = 0;
    let usedProjection = false;
    let foundProjection = false;
    if (tableExists(database, V2_TABLE)) {
      foundProjection = true;
      count = countStatuses(database, V2_TABLE, V2_STATUSES);
      usedProjection = Number(database.prepare(`SELECT COUNT(*) AS count FROM ${V2_TABLE}`).get().count) > 0;
    }
    if (!usedProjection && tableExists(database, "projection_thread_sessions")) {
      foundProjection = true;
      count = countStatuses(database, "projection_thread_sessions", V1_STATUSES);
    }
    if (!foundProjection) throw new Error("could not identify a supported activity projection");
    database.close();
    return count;
  } catch (error) {
    try { database?.close(); } catch {}
    const wrapped = new Error(`could not inspect SQLite activity database: ${error.message}`);
    wrapped.cause = error;
    throw wrapped;
  }
}

export function checkIdle(dbPath) {
  const count = activeTurnCount(dbPath);
  return { idle: count === 0, count };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const dbPath = process.argv[2];
  if (!dbPath) {
    process.stderr.write("Usage: check-idle.mjs DB_PATH\n");
    process.exit(1);
  }
  try {
    const { count } = checkIdle(dbPath);
    process.stdout.write(`${count}\n`);
    process.exit(count === 0 ? 0 : BUSY_EXIT_CODE);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
