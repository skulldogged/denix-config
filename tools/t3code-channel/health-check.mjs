#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const healthPath =
  process.argv[2] ??
  process.env.T3CODE_CHANNEL_HEALTH_FILE ??
  path.join(os.homedir(), ".local/state/t3code-channel/health.json");
const staleSeconds = Number.parseInt(
  process.env.T3CODE_CHANNEL_HEALTH_STALE_SECONDS ?? "10800",
  10,
);

function result(status, incidentKey, summary, data = {}) {
  const output = { status, summary, data };
  if (incidentKey) output.incident_key = incidentKey;
  process.stdout.write(`${JSON.stringify(output)}\n`);
}

function stableIncidentKey(health) {
  const key = health.incidentKey;
  if (typeof key === "string" && key.startsWith("merge-conflict:")) {
    return "merge-conflict";
  }
  return key ?? `${health.status}:${health.stage ?? "unknown"}:${health.checkedAt}`;
}

let health;
try {
  health = JSON.parse(fs.readFileSync(healthPath, "utf8"));
} catch (error) {
  result("problem", "health-file-unavailable", "The T3 Code channel health file is unavailable.", {
    healthPath,
    error: error instanceof Error ? error.message : String(error),
  });
  process.exit(0);
}

const checkedAt = Date.parse(health.checkedAt);
const ageSeconds = Number.isFinite(checkedAt)
  ? Math.max(0, Math.floor((Date.now() - checkedAt) / 1000))
  : null;
const data = {
  healthPath,
  channelStatus: health.status ?? null,
  stage: health.stage ?? null,
  checkedAt: health.checkedAt ?? null,
  ageSeconds,
  originSha: health.originSha ?? null,
  mainSha: health.mainSha ?? null,
  prSha: health.prSha ?? null,
  integrationSha: health.integrationSha ?? null,
  workflowUrl: health.workflowUrl ?? null,
};

if (!Number.isFinite(staleSeconds) || staleSeconds < 60) {
  result("problem", "invalid-stale-threshold", "The T3 Code health probe has an invalid stale threshold.", data);
} else if (!Number.isFinite(checkedAt)) {
  result("problem", "invalid-health-timestamp", "The T3 Code channel health timestamp is invalid.", data);
} else if (health.status === "blocked" || health.status === "failed") {
  result(
    "problem",
    stableIncidentKey(health),
    health.summary ?? `The T3 Code channel is ${health.status}.`,
    data,
  );
} else if (ageSeconds > staleSeconds) {
  result(
    "problem",
    `stale:${health.checkedAt}`,
    `The T3 Code channel has not completed a health check in ${ageSeconds} seconds.`,
    data,
  );
} else if (health.status === "healthy") {
  result("healthy", null, health.summary ?? `The T3 Code channel is ${health.status}.`, data);
} else if (health.status === "updating") {
  result("pending", null, health.summary ?? "The T3 Code channel update is still running.", data);
} else {
  result(
    "problem",
    `invalid-status:${String(health.status)}`,
    "The T3 Code channel health file contains an unknown status.",
    data,
  );
}
