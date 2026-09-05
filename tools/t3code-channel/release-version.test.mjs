import assert from "node:assert/strict";
import { test } from "node:test";
import { nextPersonalVersion } from "./release-version.mjs";

test("preserves the entire official version and starts at personal.1", () => {
  assert.equal(nextPersonalVersion("v0.0.39-nightly.20260905.1289", []),
    "0.0.39-nightly.20260905.1289.personal.1");
  assert.equal(nextPersonalVersion("v1.2.3-nightly.20260906.1290", []),
    "1.2.3-nightly.20260906.1290.personal.1");
});

test("increments only revisions of the same nightly, numerically", () => {
  assert.equal(nextPersonalVersion("v0.0.39-nightly.20260905.1289", [
    "personal-v0.0.39-nightly.20260905.1289.personal.9",
    "personal-v0.0.39-nightly.20260905.1289.personal.10",
    "personal-v0.0.39-nightly.20260905.1288.personal.99",
    "personal-v0.0.85-nightly.20260905.1289.personal.c12345678",
  ]), "0.0.39-nightly.20260905.1289.personal.11");
});

test("rejects non-nightly inputs", () => {
  assert.throws(() => nextPersonalVersion("main", []));
  assert.throws(() => nextPersonalVersion("v0.0.39", []));
});
