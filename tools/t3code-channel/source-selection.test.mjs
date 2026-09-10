import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { assertOverlayRewritesAreSafe, overlayStateChanged, pullRequestFetchSpec, readOverlayManifest } from "./source-selection.mjs";

test("reads the configured overlay manifest", () => {
  const file = path.join(os.tmpdir(), `t3-overlay-${process.pid}.json`);
  fs.writeFileSync(file, JSON.stringify([{ repository: "pingdotgg/t3code", number: 2829 }]));
  assert.deepEqual(readOverlayManifest(file), [{ repository: "pingdotgg/t3code", number: 2829, label: "PR #2829" }]);
  fs.unlinkSync(file);
});

test("rejects invalid overlay numbers and labels", () => {
  for (const entry of [
    { repository: "pingdotgg/t3code", number: 0 },
    { repository: "pingdotgg/t3code", number: 1.5 },
    { repository: "pingdotgg/t3code", number: Number.MAX_SAFE_INTEGER + 1 },
    { repository: "pingdotgg/t3code", number: 1, label: "line one\nline two" },
    { repository: "pingdotgg/t3code", number: 1, label: "tab\tlabel" },
    { repository: "pingdotgg/t3code", number: 1, label: "" },
    { repository: "pingdotgg/t3code", number: 1, label: 42 },
  ]) {
    const file = path.join(os.tmpdir(), `t3-overlay-${process.pid}-${Math.random()}.json`);
    fs.writeFileSync(file, JSON.stringify([entry]));
    assert.throws(() => readOverlayManifest(file), /positive safe integer|single-line label/);
    fs.unlinkSync(file);
  }
});

test("rejects duplicate repository and pull-request pairs", () => {
  const file = path.join(os.tmpdir(), `t3-overlay-${process.pid}-${Math.random()}.json`);
  fs.writeFileSync(file, JSON.stringify([
    { repository: "pingdotgg/t3code", number: 2829 },
    { repository: "pingdotgg/t3code", number: 2829, label: "same PR" },
  ]));
  assert.throws(() => readOverlayManifest(file), /duplicate overlay entry/);
  fs.unlinkSync(file);
});

test("detects no-op and changed overlay selections", () => {
  const source = [{ repository: "pingdotgg/t3code", number: 2829, sha: "abc" }];
  assert.equal(overlayStateChanged(source, source), false);
  assert.equal(overlayStateChanged(source, [{ ...source[0], sha: "def" }]), true);
});

test("builds an exact pull-request fetch spec", () => {
  assert.deepEqual(pullRequestFetchSpec({ repository: "pingdotgg/t3code", number: 2829 }), {
    url: "https://github.com/pingdotgg/t3code.git",
    ref: "refs/pull/2829/head",
  });
});

test("rejects a rewritten overlay head that is not an ancestor", () => {
  assert.throws(
    () => assertOverlayRewritesAreSafe(
      [{ repository: "pingdotgg/t3code", number: 2829, sha: "old" }],
      [{ repository: "pingdotgg/t3code", number: 2829, sha: "new" }],
      () => false,
    ),
    /rewritten/,
  );
});

test("permits a fast-forward overlay head", () => {
  assert.doesNotThrow(() => assertOverlayRewritesAreSafe(
    [{ repository: "pingdotgg/t3code", number: 2829, sha: "old" }],
    [{ repository: "pingdotgg/t3code", number: 2829, sha: "new" }],
    () => true,
  ));
});
