import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const required = [
	"PI_BIN",
	"PI_UNIFIED_EDIT_ROOT",
	"PI_CLAUDIFY_ROOT",
	"PI_LSP_ROOT",
	"PI_UNDO_ROOT",
	"PI_NPM_ROOT",
];
for (const name of required) {
	if (!process.env[name]) throw new Error(`${name} is required`);
}

const root = await mkdtemp(join(tmpdir(), "pi-unified-runtime-probe-"));
const agentDir = join(root, "agent");
const workspace = join(root, "workspace");
const probeRoot = join(root, "probe");
const output = join(root, "probe.json");
await mkdir(agentDir, { recursive: true });
await mkdir(workspace, { recursive: true });
await mkdir(probeRoot, { recursive: true });

const npmRoot = process.env.PI_NPM_ROOT;
const filtered = [
	join(npmRoot, "@owlburtoe/pi-claudify"),
	join(npmRoot, "lsp-pi"),
	join(npmRoot, "pi-undo-redo"),
];

await writeFile(
	join(probeRoot, "package.json"),
	JSON.stringify({
		name: "pi-unified-edit-runtime-probe",
		version: "1.0.0",
		type: "module",
		pi: { extensions: ["./probe.ts"] },
	}),
);
await writeFile(
	join(probeRoot, "probe.ts"),
	`import { writeFileSync } from "node:fs";
export default function probe(pi) {
  pi.on("session_start", () => {
    const tools = pi.getAllTools();
    writeFileSync(process.env.PI_UNIFIED_PROBE_OUTPUT, JSON.stringify({
      edits: tools.filter((tool) => tool.name === "edit"),
      lsps: tools.filter((tool) => tool.name === "lsp"),
      toolSources: tools.map((tool) => tool.sourceInfo),
      commandSources: pi.getCommands().map((command) => command.sourceInfo),
      lspGuard: globalThis[Symbol.for("pi-unified-edit:lsp-guard-compat")],
      undo: globalThis[Symbol.for("pi-unified-edit:undo-compat")],
    }));
  });
}
`,
);

const packages = [
	process.env.PI_UNIFIED_EDIT_ROOT,
	{ source: filtered[0], extensions: [] },
	process.env.PI_CLAUDIFY_ROOT,
	{ source: filtered[1], extensions: [] },
	process.env.PI_LSP_ROOT,
	{ source: filtered[2], extensions: [] },
	process.env.PI_UNDO_ROOT,
	probeRoot,
];
await writeFile(
	join(agentDir, "settings.json"),
	JSON.stringify({ packages, enableInstallTelemetry: false }),
);

try {
	const run = spawnSync(
		process.env.PI_BIN,
		[
			"--mode",
			"rpc",
			"--no-session",
			"--offline",
			"--no-skills",
			"--no-prompt-templates",
			"--no-themes",
			"--no-context-files",
		],
		{
			cwd: workspace,
			encoding: "utf8",
			input: '{"type":"get_state"}\n',
			timeout: 60_000,
			env: {
				...process.env,
				PI_CODING_AGENT_DIR: agentDir,
				PI_UNIFIED_PROBE_OUTPUT: output,
				PI_OFFLINE: "1",
				PI_TELEMETRY: "0",
			},
		},
	);
	if (run.error) throw run.error;
	if (run.status !== 0) {
		throw new Error(
			`Pi probe exited ${run.status}\nstdout:\n${run.stdout}\nstderr:\n${run.stderr}`,
		);
	}
	const state = JSON.parse(await readFile(output, "utf8"));
	if (state.edits.length !== 1)
		throw new Error(`Expected one edit tool, got ${state.edits.length}`);
	const edit = state.edits[0];
	if (!edit.parameters?.properties?.text || edit.parameters?.properties?.path) {
		throw new Error(
			`Unexpected edit schema: ${JSON.stringify(edit.parameters)}`,
		);
	}
	const source = JSON.stringify(edit.sourceInfo ?? {});
	if (!source.includes(process.env.PI_UNIFIED_EDIT_ROOT)) {
		throw new Error(`Unified Edit did not own edit: ${source}`);
	}
	if (state.lsps.length !== 1)
		throw new Error(`Expected one lsp tool, got ${state.lsps.length}`);
	const lspSource = JSON.stringify(state.lsps[0].sourceInfo ?? {});
	if (!lspSource.includes(process.env.PI_LSP_ROOT))
		throw new Error(`Patched lsp-pi did not own lsp: ${lspSource}`);
	const loadedSources = [...state.toolSources, ...state.commandSources].map(
		(sourceInfo) => JSON.stringify(sourceInfo ?? {}),
	);
	if (loadedSources.some((sourceInfo) => sourceInfo.includes("pi-lens"))) {
		throw new Error(
			`Pi Lens source unexpectedly loaded: ${loadedSources.join("\n")}`,
		);
	}
	if (state.lspGuard !== 1 || state.undo !== 1) {
		throw new Error(
			`Compatibility markers unexpected: ${JSON.stringify(state)}`,
		);
	}

	process.stdout.write(
		`${JSON.stringify({
			editCount: state.edits.length,
			editSource: edit.sourceInfo,
			schema: Object.keys(edit.parameters.properties),
			lspCount: state.lsps.length,
			lspSource: state.lsps[0].sourceInfo,
			lspGuardCompat: state.lspGuard,
			undoCompat: state.undo,
			filteredPackages: filtered,
		})}\n`,
	);
} finally {
	await rm(root, { recursive: true, force: true });
}
