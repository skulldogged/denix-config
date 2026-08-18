import { afterEach, describe, expect, test } from "bun:test";
import {
	chmod,
	lstat,
	mkdir,
	mkdtemp,
	readdir,
	readFile,
	rename,
	rm,
	symlink,
	writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.env.PI_UNIFIED_EDIT_SOURCE;
if (!source) throw new Error("PI_UNIFIED_EDIT_SOURCE is required");
const unifiedModule = await import(pathToFileURL(source).href);
const { __test } = unifiedModule;
const roots = [];

async function workspace() {
	const root = await mkdtemp(join(tmpdir(), "pi-unified-edit-test-"));
	roots.push(root);
	return root;
}

afterEach(async () => {
	__test.setCommitFailureAfter();
	__test.setFailureAfterBackup();
	__test.setRollbackRestoreFailure();
	__test.setStageFailureAfterWrite();
	__test.setAfterStage();
	delete globalThis[Symbol.for("pi-unified-edit:undo-compat")];
	await Promise.all(
		roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
	);
});

async function artifacts(root) {
	const found = [];
	async function visit(path) {
		for (const entry of await readdir(path, { withFileTypes: true })) {
			const child = join(path, entry.name);
			if (entry.isDirectory()) await visit(child);
			else if (entry.name.startsWith(".pi-unified-edit-")) found.push(child);
		}
	}
	await visit(root);
	return found;
}

describe("Unified Edit hardening", () => {
	test("parses row and patch payloads", () => {
		expect(
			__test.parseRowScript("[a.txt]\n@REPLACE\n-old\n+new\n"),
		).toHaveLength(1);
		expect(
			__test.parsePatch(
				"*** Begin Patch\n*** Add File: a.txt\n+hello\n*** End Patch",
			),
		).toHaveLength(1);
	});

	test("rejects existing Add File", async () => {
		const root = await workspace();
		await writeFile(join(root, "a.txt"), "old\n");
		await expect(
			__test.buildPlan(
				"*** Begin Patch\n*** Add File: a.txt\n+new\n*** End Patch",
				root,
			),
		).rejects.toThrow("already exists");
	});

	test("allows out-of-workspace paths and rejects symlink components", async () => {
		const root = await workspace();
		const outside = await workspace();
		const outsidePath = join(outside, "x.txt");
		await writeFile(outsidePath, "x\n");
		await symlink(outside, join(root, "link"));
		const plan = await __test.buildPlan(
			`[${outsidePath}]\n@APPEND\n+y\n`,
			root,
		);
		await __test.applyPlan(plan);
		expect(await readFile(outsidePath, "utf8")).toBe("x\ny\n");
		await expect(
			__test.buildPlan("[link/x.txt]\n@APPEND\n+x\n", root),
		).rejects.toThrow("Symlink paths");
	});

	test("creates a new file from a row script", async () => {
		const root = await workspace();
		const path = join(root, "new.txt");
		const plan = await __test.buildPlan("[new.txt]\n@APPEND\n+new\n", root);
		await __test.applyPlan(plan);
		expect(await readFile(path, "utf8")).toBe("new\n");
	});

	test("requires unique patch matches", async () => {
		const root = await workspace();
		await writeFile(join(root, "a.txt"), "same\nsame\n");
		const patch =
			"*** Begin Patch\n*** Update File: a.txt\n@@\n-same\n+changed\n*** End Patch";
		await expect(__test.buildPlan(patch, root)).rejects.toThrow("ambiguous");
	});

	test("applies multi-file update, add, and delete", async () => {
		const root = await workspace();
		await writeFile(join(root, "a.txt"), "one\n");
		await writeFile(join(root, "d.txt"), "delete\n");
		const patch =
			"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+ONE\n*** Add File: b.txt\n+added\n*** Delete File: d.txt\n*** End Patch";
		const plan = await __test.buildPlan(patch, root);
		const details = await __test.applyPlan(plan);
		expect(details.files.map((file) => file.kind)).toEqual([
			"update",
			"add",
			"delete",
		]);
		expect(await readFile(join(root, "a.txt"), "utf8")).toBe("ONE\n");
		expect(await readFile(join(root, "b.txt"), "utf8")).toBe("added\n");
		await expect(lstat(join(root, "d.txt"))).rejects.toMatchObject({
			code: "ENOENT",
		});
	});

	test("rolls back earlier files when a later commit fails", async () => {
		const root = await workspace();
		await writeFile(join(root, "a.txt"), "one\n");
		const patch =
			"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+ONE\n*** Add File: b.txt\n+added\n*** End Patch";
		const plan = await __test.buildPlan(patch, root);
		__test.setCommitFailureAfter(1);
		await expect(__test.applyPlan(plan)).rejects.toThrow(
			"Injected commit failure",
		);
		expect(await readFile(join(root, "a.txt"), "utf8")).toBe("one\n");
		await expect(lstat(join(root, "b.txt"))).rejects.toMatchObject({
			code: "ENOENT",
		});
		expect(await artifacts(root)).toEqual([]);
	});

	test("restores a backup after failure between backup and stage rename", async () => {
		const root = await workspace();
		const path = join(root, "a.txt");
		await writeFile(path, "one\n");
		const plan = await __test.buildPlan(
			"[a.txt]\n@REPLACE\n-one\n+ONE\n",
			root,
		);
		__test.setFailureAfterBackup(true);
		await expect(__test.applyPlan(plan)).rejects.toThrow("after backup rename");
		expect(await readFile(path, "utf8")).toBe("one\n");
		expect(await artifacts(root)).toEqual([]);
	});

	test("retains and reports a backup when rollback restore fails", async () => {
		const root = await workspace();
		const path = join(root, "a.txt");
		await writeFile(path, "one\n");
		const plan = await __test.buildPlan(
			"[a.txt]\n@REPLACE\n-one\n+ONE\n",
			root,
		);
		__test.setFailureAfterBackup(true);
		__test.setRollbackRestoreFailure(true);
		let message = "";
		try {
			await __test.applyPlan(plan);
		} catch (error) {
			message = error.message;
		}
		expect(message).toContain("original retained at");
		const retained = (await artifacts(root)).filter((path) =>
			path.endsWith(".backup"),
		);
		expect(retained).toHaveLength(1);
		expect(message).toContain(retained[0]);
		expect(await readFile(retained[0], "utf8")).toBe("one\n");
	});

	test("cleans artifacts and empty add directories on abort after staging", async () => {
		const root = await workspace();
		const controller = new AbortController();
		const plan = await __test.buildPlan(
			"*** Begin Patch\n*** Add File: nested/deep/a.txt\n+added\n*** End Patch",
			root,
		);
		__test.setAfterStage(() => controller.abort());
		await expect(__test.applyPlan(plan, controller.signal)).rejects.toThrow();
		expect(await artifacts(root)).toEqual([]);
		await expect(lstat(join(root, "nested"))).rejects.toMatchObject({
			code: "ENOENT",
		});
	});

	test("cleans a stage file when a post-write staging step fails", async () => {
		const root = await workspace();
		const plan = await __test.buildPlan(
			"*** Begin Patch\n*** Add File: nested/a.txt\n+added\n*** End Patch",
			root,
		);
		__test.setStageFailureAfterWrite(true);
		await expect(__test.applyPlan(plan)).rejects.toThrow("staging failure");
		expect(await artifacts(root)).toEqual([]);
		await expect(lstat(join(root, "nested"))).rejects.toMatchObject({
			code: "ENOENT",
		});
	});

	test("never recursively deletes external contents from an add directory", async () => {
		const root = await workspace();
		const controller = new AbortController();
		const plan = await __test.buildPlan(
			"*** Begin Patch\n*** Add File: nested/a.txt\n+added\n*** End Patch",
			root,
		);
		__test.setAfterStage(async () => {
			await writeFile(join(root, "nested/external.txt"), "keep\n");
			controller.abort();
		});
		await expect(__test.applyPlan(plan, controller.signal)).rejects.toThrow();
		expect(await readFile(join(root, "nested/external.txt"), "utf8")).toBe(
			"keep\n",
		);
		expect(await artifacts(root)).toEqual([]);
	});

	test("rejects raw stale changes including EOL-only drift", async () => {
		const root = await workspace();
		const path = join(root, "a.txt");
		await writeFile(path, "one\n");
		const plan = await __test.buildPlan(
			"[a.txt]\n@REPLACE\n-one\n+ONE\n",
			root,
		);
		await writeFile(path, "one\r\n");
		await expect(__test.applyPlan(plan)).rejects.toThrow(
			"raw file contents changed",
		);
		expect(await readFile(path, "utf8")).toBe("one\r\n");
	});

	test("rejects raw-identical inode replacement after staging", async () => {
		const root = await workspace();
		const path = join(root, "a.txt");
		const replaced = join(root, "replaced.txt");
		await writeFile(path, "one\n");
		const plan = await __test.buildPlan(
			"[a.txt]\n@REPLACE\n-one\n+ONE\n",
			root,
		);
		__test.setAfterStage(async () => {
			await rename(path, replaced);
			await writeFile(path, "one\n");
		});
		await expect(__test.applyPlan(plan)).rejects.toThrow(
			"target identity changed",
		);
		expect(await readFile(path, "utf8")).toBe("one\n");
		expect(await artifacts(root)).toEqual([]);
	});

	test("rejects mode-only drift after staging", async () => {
		const root = await workspace();
		const path = join(root, "a.txt");
		await writeFile(path, "one\n");
		await chmod(path, 0o640);
		const plan = await __test.buildPlan(
			"[a.txt]\n@REPLACE\n-one\n+ONE\n",
			root,
		);
		__test.setAfterStage(() => chmod(path, 0o600));
		await expect(__test.applyPlan(plan)).rejects.toThrow("file mode changed");
		expect(await artifacts(root)).toEqual([]);
	});

	test("preserves BOM, CRLF, final newline, and all mode bits", async () => {
		const root = await workspace();
		const path = join(root, "a.txt");
		await writeFile(path, "\uFEFFone\r\ntwo");
		await chmod(path, 0o7640);
		// Some sandbox filesystems strip special bits; preserve every bit accepted.
		const expectedMode = (await lstat(path)).mode & 0o7777;
		const plan = await __test.buildPlan(
			"[a.txt]\n@REPLACE\n-one\n+ONE\n",
			root,
		);
		await __test.applyPlan(plan);
		expect(await readFile(path, "utf8")).toBe("\uFEFFONE\r\ntwo");
		expect((await lstat(path)).mode & 0o7777).toBe(expectedMode);
	});

	test("emits a private versioned manifest with canonical paths and narrow edits", async () => {
		const root = await workspace();
		await mkdir(join(root, "src"));
		await writeFile(join(root, "src/a.txt"), "before\nkeep\n");
		const plan = await __test.buildPlan(
			"[src/a.txt]\n@REPLACE\n-before\n+after\n",
			root,
		);
		const manifest = __test.manifestForPlan(plan);
		expect(manifest.version).toBe(1);
		expect(manifest.files[0].absolutePath).toBe(join(root, "src/a.txt"));
		expect(manifest.files[0].edits).toHaveLength(1);
		expect(manifest.files[0].edits[0].oldText).toContain("before");
		expect(manifest.files[0].edits[0].oldText.length).toBeLessThanOrEqual(
			"before\nkeep\n".length,
		);
	});

	test("fails closed, attaches manifests, executes, and clears blocked plans", async () => {
		const root = await workspace();
		const path = join(root, "a.txt");
		await writeFile(path, "one\n");
		const handlers = new Map();
		let tool;
		unifiedModule.default({
			on(name, handler) {
				handlers.set(name, handler);
			},
			registerTool(definition) {
				tool = definition;
			},
		});
		const input = { text: "[a.txt]\n@REPLACE\n-one\n+ONE\n" };
		const event = { toolName: "write", toolCallId: "call-1", input };
		const undo = Symbol.for("pi-unified-edit:undo-compat");
		delete globalThis[undo];
		expect((await handlers.get("tool_call")(event, { cwd: root })).block).toBe(
			true,
		);

		globalThis[undo] = 1;
		expect(
			await handlers.get("tool_call")(event, { cwd: root }),
		).toBeUndefined();
		expect(input.__piUnifiedEdit.version).toBe(1);
		await handlers.get("turn_end")();
		await writeFile(path, "external\n");
		await expect(
			tool.execute("call-1", input, undefined, undefined, { cwd: root }),
		).rejects.toThrow();

		await writeFile(path, "one\n");
		const input2 = { text: input.text };
		await handlers.get("tool_call")(
			{ toolName: "write", toolCallId: "call-2", input: input2 },
			{ cwd: root },
		);
		await tool.execute("call-2", input2, undefined, undefined, { cwd: root });
		expect(await readFile(path, "utf8")).toBe("ONE\n");
		await handlers.get("tool_result")({
			toolName: "write",
			toolCallId: "call-2",
		});
		await handlers.get("session_shutdown")();
		delete globalThis[undo];
	});

	test("deduplicates canonical targets and includes write content", async () => {
		const root = await workspace();
		await writeFile(join(root, "empty.txt"), "");
		const plan = await __test.buildPlan(
			"*** Begin Patch\n*** Update File: empty.txt\n@@\n+one\n*** Update File: empty.txt\n@@\n+two\n*** End Patch",
			root,
		);
		expect(plan.changes).toHaveLength(1);
		const manifest = __test.manifestForPlan(plan);
		expect(manifest.files).toHaveLength(1);
		expect(manifest.files[0].kind).toBe("write");
		expect(manifest.files[0].content).toBe("one\ntwo\n");
	});
});
