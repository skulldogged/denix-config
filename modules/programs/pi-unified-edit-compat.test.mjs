import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const claudifyRoot = process.env.PI_CLAUDIFY_SOURCE;
const lspRoot = process.env.PI_LSP_SOURCE;
const undoRoot = process.env.PI_UNDO_SOURCE;
if (!claudifyRoot || !lspRoot || !undoRoot)
	throw new Error(
		"PI_CLAUDIFY_SOURCE, PI_LSP_SOURCE, and PI_UNDO_SOURCE are required",
	);

const claudify = await readFile(
	join(claudifyRoot, "extensions/index.ts"),
	"utf8",
);
const hook = await readFile(join(lspRoot, "lsp.ts"), "utf8");
const guard = await readFile(join(lspRoot, "lsp-guard.ts"), "utf8");
const undo = await readFile(join(undoRoot, "src/extension.ts"), "utf8");

describe("Unified Edit lightweight compatibility patches", () => {
	test("Claudify styles Unified Edit without competing for execution", () => {
		expect(claudify).toContain("Unified Edit owns execution");
		expect(claudify).not.toContain('name: "edit",');
		expect(claudify).toContain('name: "write",');
		expect(claudify).toContain('toolName === "edit"');
		expect(claudify).toContain("renderUnifiedEditCall");
		expect(claudify).toContain("renderUnifiedEditResult");
		expect(claudify).toContain("renderDiff(diff)");
		expect(claudify).toContain("diffCollapsedLimit()");
	});

	test("lsp-pi consumes Unified manifests/results and fails closed through the guard marker", () => {
		expect(hook).toContain("__piUnifiedEdit");
		expect(hook).toContain("event.details as any).files");
		expect(hook).toContain("if (event.isError) return");
		expect(guard).toContain('Symbol.for("pi-unified-edit:lsp-guard-compat")');
		expect(guard).toContain("Read guard requires a full current read");
	});

	test("undo publishes marker and captures each manifest path once", () => {
		expect(undo).toContain('Symbol.for("pi-unified-edit:undo-compat")');
		expect(undo).toContain("manifest?.version === 1");
		expect(undo).toContain("new Set(manifest.files");
		expect(undo).toContain(
			"for (const filePath of paths) await captureExplicitToolPath",
		);
	});
});
