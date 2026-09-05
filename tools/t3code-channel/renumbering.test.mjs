import assert from "node:assert/strict";
import { test } from "node:test";
import { isPersonalRenumbering } from "./renumbering.mjs";

test("permits only the legacy personal channel to official-aligned personal channel", () => {
  const old = "0.0.84-mainc8f77e0d.pi.ce4ebc5e5";
  const next = "0.0.39-nightly.20260905.1289.personal.1";
  assert.equal(isPersonalRenumbering(old, next), true);
  assert.equal(isPersonalRenumbering(next, old), false);
  assert.equal(isPersonalRenumbering("0.0.84", next), false);
  assert.equal(isPersonalRenumbering(old, "0.0.39"), false);
  assert.equal(isPersonalRenumbering(next, "0.0.39-nightly.20260904.1280.personal.1"), false);
});
