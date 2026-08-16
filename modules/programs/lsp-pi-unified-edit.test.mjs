import { afterEach, describe, expect, test } from "bun:test";
import {
	mkdir,
	mkdtemp,
	readFile,
	rename,
	rm,
	writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const root = process.env.PI_LSP_SOURCE;
if (!root) throw new Error("PI_LSP_SOURCE is required");
const coreModule = await import(pathToFileURL(join(root, "lsp-core.ts")).href);
const hookModule = await import(pathToFileURL(join(root, "lsp.ts")).href);
const roots = [];

async function workspace() {
	const dir = await mkdtemp(join(tmpdir(), "lsp-pi-guard-test-"));
	roots.push(dir);
	return dir;
}

afterEach(async () => {
	await coreModule.shutdownManager();
	await Promise.all(
		roots.splice(0).map((dir) => rm(dir, { recursive: true, force: true })),
	);
});

describe("agent-end diagnostics batching", () => {
	test("deduplicates warning policy and emits one combined message", async () => {
		const batch = hookModule.createTouchedBatchState();
		batch.add("a.ts", false);
		batch.add("a.ts", true);
		batch.add("b.ts", false);
		const sent = [];
		expect(
			await batch.flush(
				() => true,
				async (path, warnings) => `${path}:${warnings}`,
				(content) => sent.push(content),
			),
		).toBe(true);
		expect(sent).toEqual(["a.ts:true\nb.ts:false"]);
		expect(batch.touchedFiles.size).toBe(0);
	});

	test("retains the full batch when the initial boundary is unsafe", async () => {
		const batch = hookModule.createTouchedBatchState();
		batch.add("a.ts", false);
		expect(
			await batch.flush(
				() => false,
				async () => "unused",
				() => {},
			),
		).toBe(false);
		expect([...batch.touchedFiles]).toEqual([["a.ts", false]]);
	});

	test("retains every entry and sends nothing when safety changes mid-batch", async () => {
		const batch = hookModule.createTouchedBatchState();
		batch.add("a.ts", false);
		batch.add("b.ts", true);
		let safe = true;
		const sent = [];
		expect(
			await batch.flush(
				() => safe,
				async () => {
					safe = false;
					return "partial";
				},
				(content) => sent.push(content),
			),
		).toBe(false);
		expect(sent).toEqual([]);
		expect([...batch.touchedFiles]).toEqual([
			["a.ts", false],
			["b.ts", true],
		]);
	});
});

describe("lsp-pi compatibility source", () => {
	test("registers nixd with flake root and stdio-compatible empty args", async () => {
		expect(coreModule.LANGUAGE_IDS[".nix"]).toBe("nix");
		const nixd = coreModule.LSP_SERVERS.find((server) => server.id === "nixd");
		expect(nixd).toBeDefined();
		const cwd = await workspace();
		await writeFile(join(cwd, "flake.nix"), "{}\n");
		await mkdir(join(cwd, "nested"));
		expect(nixd.findRoot(join(cwd, "nested/a.nix"), cwd)).toBe(cwd);
	});

	test("real nixd returns a bounded diagnostic response", async () => {
		const cwd = await workspace();
		await writeFile(
			join(cwd, "flake.nix"),
			"{ outputs = { self }: { bad = builtins.noSuchBuiltin 1; }; }\n",
		);
		const result = await coreModule
			.getOrCreateManager(cwd)
			.touchFileAndWait(join(cwd, "flake.nix"), 10_000);
		expect(result.unsupported).not.toBe(true);
		expect(result.receivedResponse).toBe(true);
		expect(result.diagnostics.length).toBeGreaterThan(0);
	});

	test("hook recognizes successful Unified Write details and excludes deletes/errors", async () => {
		const source = await readFile(join(root, "lsp.ts"), "utf8");
		expect(source).toContain('"flake.nix": ".nix"');
		expect(source).toContain("if (event.isError) return");
		expect(source).toContain('file?.kind === "delete"');
		expect(source).toContain("event.details as any).files");
		expect(source).toContain("diagnosticsBatch.add(absPath");
		expect(source).toContain("createTouchedBatchState");
		expect(source).not.toContain('pi.on("session_switch"');
		expect(source).not.toContain('pi.on("session_fork"');
	});
});
