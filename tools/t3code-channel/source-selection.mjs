import fs from "node:fs";

export function readOverlayManifest(path) {
  const entries = JSON.parse(fs.readFileSync(path, "utf8"));
  if (!Array.isArray(entries)) {
    throw new Error("overlay manifest must contain an array");
  }
  const seen = new Set();
  return entries.map((entry) => {
    if (
      !entry
      || typeof entry.repository !== "string"
      || !/^[\w.-]+\/[\w.-]+$/.test(entry.repository)
      || !Number.isSafeInteger(entry.number)
      || entry.number < 1
      || (entry.label !== undefined && (typeof entry.label !== "string" || entry.label.length === 0 || /[\r\n\t]/.test(entry.label)))
    ) {
      throw new Error("overlay entries require repository, positive safe integer number, and single-line label");
    }
    const key = `${entry.repository}#${entry.number}`;
    if (seen.has(key)) throw new Error(`duplicate overlay entry: ${key}`);
    seen.add(key);
    return { repository: entry.repository, number: entry.number, label: entry.label ?? `PR #${entry.number}` };
  });
}

export function pullRequestFetchSpec(overlay) {
  return {
    url: `https://github.com/${overlay.repository}.git`,
    ref: `refs/pull/${overlay.number}/head`,
  };
}

export function overlayStateChanged(previous, current) {
  return JSON.stringify(previous ?? []) !== JSON.stringify(current);
}

export function assertOverlayRewritesAreSafe(previous, current, isAncestor) {
  for (const overlay of current) {
    const oldSha = previous?.find((entry) => entry.repository === overlay.repository && entry.number === overlay.number)?.sha;
    if (oldSha && oldSha !== overlay.sha && !isAncestor(oldSha, overlay.sha)) {
      throw new Error(`overlay ${overlay.repository}#${overlay.number} was rewritten; manual integration is required`);
    }
  }
}
