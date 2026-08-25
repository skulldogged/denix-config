import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { copyFile, open, readFile, rename } from "node:fs/promises";
import http from "node:http";
import path from "node:path";

const [baseDir, expectedVersion, targetVersion, unit = "t3code.service"] = process.argv.slice(2);
const exactVersion = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

const compareVersions = (left, right) => {
  const parse = (version) => {
    const separator = version.indexOf("-");
    const core = separator === -1 ? version : version.slice(0, separator);
    return {
      core: core.split(".").map(BigInt),
      prerelease: separator === -1 ? null : version.slice(separator + 1).split("."),
    };
  };
  const x = parse(left);
  const y = parse(right);
  for (let index = 0; index < 3; index += 1) {
    if (x.core[index] !== y.core[index]) return x.core[index] < y.core[index] ? -1 : 1;
  }
  if (x.prerelease === null || y.prerelease === null) {
    return x.prerelease === y.prerelease ? 0 : x.prerelease === null ? 1 : -1;
  }
  const length = Math.max(x.prerelease.length, y.prerelease.length);
  for (let index = 0; index < length; index += 1) {
    const xPart = x.prerelease[index];
    const yPart = y.prerelease[index];
    if (xPart === undefined || yPart === undefined) return xPart === yPart ? 0 : xPart === undefined ? -1 : 1;
    if (xPart === yPart) continue;
    const xNumeric = /^\d+$/.test(xPart);
    const yNumeric = /^\d+$/.test(yPart);
    if (xNumeric && yNumeric) return BigInt(xPart) < BigInt(yPart) ? -1 : 1;
    if (xNumeric !== yNumeric) return xNumeric ? -1 : 1;
    return xPart < yPart ? -1 : 1;
  }
  return 0;
};

if (!baseDir || !exactVersion.test(expectedVersion ?? "") || !exactVersion.test(targetVersion ?? "")) {
  throw new Error("Usage: switch-service.mjs BASE_DIR EXPECTED_VERSION TARGET_VERSION [UNIT]");
}
if (compareVersions(targetVersion, expectedVersion) <= 0) {
  throw new Error(`Target version ${targetVersion} must be newer than ${expectedVersion}`);
}

const statePath = path.join(baseDir, "runtime/service-state.json");
const dbPath = path.join(baseDir, "userdata/state.sqlite");
const sentinelPath = path.join(baseDir, "runtime/versions", targetVersion, ".install-complete");
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const log = (message) => process.stdout.write(`${new Date().toISOString()} ${message}\n`);

const writeState = async (state) => {
  const temporaryPath = `${statePath}.switch-${process.pid}`;
  const handle = await open(temporaryPath, "wx", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(state, null, 2)}\n`);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await rename(temporaryPath, statePath);
  const directory = await open(path.dirname(statePath), "r");
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
};

const httpReady = () =>
  new Promise((resolve) => {
    const request = http.get("http://127.0.0.1:3773/", (response) => {
      response.resume();
      resolve(response.statusCode === 200);
    });
    request.setTimeout(2_000, () => request.destroy());
    request.on("error", () => resolve(false));
  });

const current = JSON.parse(await readFile(statePath, "utf8"));
if (current.protocol !== 2 || current.activeVersion !== expectedVersion) {
  throw new Error(`Unexpected active service state: ${JSON.stringify(current)}`);
}
if ((await readFile(sentinelPath, "utf8")).trim() !== targetVersion) {
  throw new Error(`Candidate sentinel does not match ${targetVersion}`);
}

const backupPath = `${statePath}.before-${targetVersion}.json`;
await copyFile(statePath, backupPath);
const updateId = randomUUID();
await writeState({
  protocol: 2,
  activeVersion: expectedVersion,
  update: {
    id: updateId,
    fromVersion: expectedVersion,
    targetVersion,
    dbPath,
    status: "pending",
  },
});
log(`Recorded pending update ${updateId}.`);

const restart = spawnSync("systemctl", ["--user", "restart", unit], { encoding: "utf8" });
if (restart.status !== 0) {
  throw new Error(`systemctl restart failed: ${restart.stderr || restart.stdout}`);
}
log("Restarted the service launcher.");

for (let attempt = 0; attempt < 90; attempt += 1) {
  await sleep(2_000);
  const state = JSON.parse(await readFile(statePath, "utf8"));
  const update = state.update;
  if (state.activeVersion === targetVersion && update?.id === updateId && update.status === "committed") {
    for (let healthAttempt = 0; healthAttempt < 30; healthAttempt += 1) {
      if (await httpReady()) {
        log(`SUCCESS: ${targetVersion} committed and HTTP is ready.`);
        process.exit(0);
      }
      await sleep(1_000);
    }
    throw new Error("The candidate committed but HTTP did not become ready.");
  }
  if (
    state.activeVersion === expectedVersion &&
    update?.id === updateId &&
    (update.status === "rolled-back" || update.status === "failed")
  ) {
    throw new Error(`Candidate ${update.status}: ${update.reason ?? "unspecified reason"}`);
  }
}

throw new Error("Timed out waiting for the service launcher trial outcome.");
