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
const guardModule = await import(
	pathToFileURL(join(root, "lsp-guard.ts")).href
);
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

function readEvent(path, text = "a\n", overrides = {}) {
	return {
		toolName: "read",
		toolCallId: "read-1",
		input: { path },
		content: [{ type: "text", text }],
		details: {},
		isError: false,
		...overrides,
	};
}
function writeCall(id, path) {
	return { toolName: "write", toolCallId: id, input: { path } };
}
function writeResult(id, path, isError = false) {
	return {
		toolName: "write",
		toolCallId: id,
		input: { path },
		details: {},
		isError,
	};
}
function unifiedCall(id, files) {
	return {
		toolName: "edit",
		toolCallId: id,
		input: { text: "patch", __piUnifiedEdit: { version: 1, files } },
	};
}
function unifiedResult(id, files, isError = false) {
	return { ...unifiedCall(id, files), details: { files }, isError };
}

describe("lightweight file-level read guard", () => {
	test("full reads authorize; partial, limited, truncated, and failed reads do not", async () => {
		const cwd = await workspace();
		await writeFile(join(cwd, "a.txt"), "a\n");
		for (const overrides of [
			{ input: { path: "a.txt", offset: 1 } },
			{ input: { path: "a.txt", limit: 10 } },
			{ details: { truncation: { truncated: true } } },
			{ isError: true },
		]) {
			const state = guardModule.__test.createReadGuardState();
			await state.authorizeRead(readEvent("a.txt", "a\n", overrides), cwd);
			expect(await state.reserve(writeCall("w", "a.txt"), cwd)).toMatchObject({
				block: true,
			});
		}
		const state = guardModule.__test.createReadGuardState();
		await state.authorizeRead(readEvent("a.txt"), cwd);
		expect(await state.reserve(writeCall("w", "a.txt"), cwd)).toBeUndefined();
	});

	test("does not authorize when model-visible read content differs from current bytes", async () => {
		const cwd = await workspace();
		const file = join(cwd, "a.txt");
		await writeFile(file, "new\n");
		const state = guardModule.__test.createReadGuardState();
		await state.authorizeRead(readEvent("a.txt", "old\n"), cwd);
		expect(await state.reserve(writeCall("w", "a.txt"), cwd)).toMatchObject({
			block: true,
		});
	});

	test("images and mixed-content reads do not authorize", async () => {
		const cwd = await workspace();
		await writeFile(join(cwd, "a.txt"), "a\n");
		for (const content of [
			[{ type: "image", data: "...", mimeType: "image/png" }],
			[
				{ type: "text", text: "a\n" },
				{ type: "image", data: "...", mimeType: "image/png" },
			],
		]) {
			const state = guardModule.__test.createReadGuardState();
			await state.authorizeRead(readEvent("a.txt", "a\n", { content }), cwd);
			expect(await state.reserve(writeCall("w", "a.txt"), cwd)).toMatchObject({
				block: true,
			});
		}
	});

	test("blocks unread, stale-byte, and same-byte inode replacement", async () => {
		const cwd = await workspace();
		const file = join(cwd, "a.txt");
		await writeFile(file, "a\n");
		const unread = guardModule.__test.createReadGuardState();
		expect(
			(await unread.reserve(writeCall("u", "a.txt"), cwd)).reason,
		).toContain("full current read");

		const stale = guardModule.__test.createReadGuardState();
		await stale.authorizeRead(readEvent("a.txt"), cwd);
		await writeFile(file, "b\n");
		expect(
			(await stale.reserve(writeCall("s", "a.txt"), cwd)).reason,
		).toContain("stale");

		const replaced = guardModule.__test.createReadGuardState();
		await writeFile(file, "a\n");
		await replaced.authorizeRead(readEvent("a.txt"), cwd);
		await rename(file, join(cwd, "old.txt"));
		await writeFile(file, "a\n");
		expect(
			(await replaced.reserve(writeCall("r", "a.txt"), cwd)).reason,
		).toContain("identity");
	});

	test("new files are exempt and successful own writes refresh authorization", async () => {
		const cwd = await workspace();
		const state = guardModule.__test.createReadGuardState();
		expect(
			await state.reserve(writeCall("new", "new.txt"), cwd),
		).toBeUndefined();
		await writeFile(join(cwd, "new.txt"), "one\n");
		await state.finish(writeResult("new", "new.txt"), cwd);
		expect(
			await state.reserve(writeCall("again", "new.txt"), cwd),
		).toBeUndefined();
	});

	test("Unified manifests authorize all-or-nothing and exempt only adds", async () => {
		const cwd = await workspace();
		await writeFile(join(cwd, "a.txt"), "a\n");
		await writeFile(join(cwd, "b.txt"), "b\n");
		const state = guardModule.__test.createReadGuardState();
		await state.authorizeRead(readEvent("a.txt"), cwd);
		const files = [
			{ absolutePath: join(cwd, "a.txt"), kind: "update" },
			{ absolutePath: join(cwd, "b.txt"), kind: "delete" },
			{ absolutePath: join(cwd, "new.txt"), kind: "add" },
		];
		expect(
			(await state.reserve(unifiedCall("unified", files), cwd)).reason,
		).toContain("b.txt");
		expect(state.reservations.size).toBe(0);
		await state.authorizeRead(readEvent("b.txt", "b\n"), cwd);
		expect(
			await state.reserve(unifiedCall("unified-2", files), cwd),
		).toBeUndefined();
	});

	test("overlapping sibling mutations are reserved by toolCallId", async () => {
		const cwd = await workspace();
		await writeFile(join(cwd, "a.txt"), "a\n");
		const state = guardModule.__test.createReadGuardState();
		await state.authorizeRead(readEvent("a.txt"), cwd);
		expect(await state.reserve(writeCall("one", "a.txt"), cwd)).toBeUndefined();
		expect(
			(await state.reserve(writeCall("two", "a.txt"), cwd)).reason,
		).toContain("overlapping");
		state.release("one");
		expect(await state.reserve(writeCall("two", "a.txt"), cwd)).toBeUndefined();
	});

	test("failed results refresh nothing; successful Unified results refresh and delete", async () => {
		const cwd = await workspace();
		const a = join(cwd, "a.txt");
		const b = join(cwd, "b.txt");
		await writeFile(a, "a\n");
		await writeFile(b, "b\n");
		const state = guardModule.__test.createReadGuardState();
		await state.authorizeRead(readEvent("a.txt", "a\n"), cwd);
		await state.authorizeRead(readEvent("b.txt", "b\n"), cwd);
		const files = [
			{ absolutePath: a, kind: "update" },
			{ absolutePath: b, kind: "delete" },
		];
		await state.reserve(unifiedCall("unified", files), cwd);
		await writeFile(a, "changed\n");
		await state.finish(unifiedResult("unified", files, true), cwd);
		expect(
			(await state.reserve(writeCall("stale", "a.txt"), cwd)).reason,
		).toContain("stale");

		await state.authorizeRead(readEvent("a.txt", "changed\n"), cwd);
		await state.reserve(unifiedCall("ok", files), cwd);
		await writeFile(a, "done\n");
		await rm(b);
		await state.finish(unifiedResult("ok", files), cwd);
		expect(
			await state.reserve(writeCall("next", "a.txt"), cwd),
		).toBeUndefined();
		state.release("next");
		expect(
			await state.reserve(writeCall("recreate", "b.txt"), cwd),
		).toBeUndefined();
	});
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

	test("hook recognizes successful Unified details and excludes deletes/errors", async () => {
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
