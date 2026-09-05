import { pathToFileURL } from "node:url";

export function nextPersonalVersion(nightlyTag, tags) {
  if (!/^v\d+\.\d+\.\d+-nightly\.\d{8}\.\d+$/.test(nightlyTag)) {
    throw new Error(`Invalid official nightly tag: ${nightlyTag}`);
  }
  const base = `${nightlyTag.slice(1)}.personal.`;
  const prefix = `personal-v${base}`;
  let revision = 0;
  for (const tag of tags) {
    if (!tag.startsWith(prefix)) continue;
    const suffix = tag.slice(prefix.length);
    if (!/^[1-9]\d*$/.test(suffix)) continue;
    const value = Number(suffix);
    if (!Number.isSafeInteger(value) || value >= Number.MAX_SAFE_INTEGER) {
      throw new Error(`Invalid personal revision: ${tag}`);
    }
    revision = Math.max(revision, value);
  }
  return `${base}${revision + 1}`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(nextPersonalVersion(process.argv[2], (process.argv[3] ?? "").split("\n")));
}
