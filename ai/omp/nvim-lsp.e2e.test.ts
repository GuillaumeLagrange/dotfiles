// End to end: the nvim-bridge extension against a throwaway headless nvim running the real
// config from this checkout, serving rust-analyzer (rustaceanvim) and ts_ls on small fixtures.
// Run with: cd ai/omp && npm run test:e2e
//
// Isolated from the nvims and omps in use: private XDG state/cache dirs and bridge registry.
// Plugins come from the real XDG data dir. typescript-language-server is taken from nixpkgs.

import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, assert, beforeAll, describe, it } from "vitest";
import { fakePi } from "./fake-pi.ts";

const ROOT = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "nvim-lsp-e2e-")));
const PROJECT = path.join(ROOT, "project");
process.env.OMP_NVIM_BRIDGE_DIR = path.join(ROOT, "run");
process.env.OMP_NVIM_LSP_EDIT_BUDGET_MS = "20000";
delete process.env.ZELLIJ_SESSION_NAME;
delete process.env.ZELLIJ_PANE_ID;

// Dynamic: the extension reads OMP_NVIM_BRIDGE_DIR at import time, so the env above comes first.
const { default: nvimBridge } = await import("./extensions/nvim-bridge/index.ts");

const NVIM_CONFIG = path.resolve(import.meta.dirname, "../../nvim");
const SOCK = path.join(ROOT, "nvim.sock");

function write(rel: string, content: string): string {
	const file = path.join(PROJECT, rel);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, content);
	return file;
}

function fixtures() {
	write("rs/Cargo.toml", '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2021"\n');
	write("rs/src/util.rs", "pub fn two() -> i32 {\n    2\n}\n");
	write(
		"rs/src/main.rs",
		"mod util;\n\nfn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\nfn main() {\n    let x = add(1, util::two());\n    println!(\"{x}\");\n}\n",
	);
	write(
		"ts/tsconfig.json",
		'{ "compilerOptions": { "strict": true, "target": "es2022", "module": "nodenext", "noEmit": true }, "include": ["src"] }\n',
	);
	write("ts/package.json", '{ "name": "fixture", "type": "module" }\n');
	write("ts/src/a.ts", "export function add(a: number, b: number): number {\n  return a + b;\n}\n");
	write("ts/src/b.ts", 'import { add } from "./a.js";\nexport const x: number = add(1, 2);\n');
	write("README.md", "# fixture\n");
}

/** Evaluates Lua in the test nvim, like a user poking at it. */
function lua(code: string): string {
	return execFileSync("nvim", ["--server", SOCK, "--remote-expr", `luaeval('${code.replaceAll("'", "''")}')`], {
		encoding: "utf8",
	}).trim();
}

const { pi, handlers, tools } = fakePi();
const ctx = {
	hasUI: true,
	cwd: PROJECT,
	ui: { pasteToEditor() {}, getEditorText: () => "", setEditorText() {} },
};

async function lsp(params: Record<string, unknown>): Promise<string> {
	const tool = tools.get("lsp");
	assert.ok(tool, "lsp tool registered");
	const res = await tool.execute("id", params as never, undefined, undefined, ctx);
	return res.content.map((c) => c.text).join("\n");
}

/** What omp shows after a `write` of `rel`: the tool output plus the diagnostics hook. */
async function omp_write(rel: string, content: string): Promise<string> {
	const file = write(rel, content);
	const res = (await handlers.get("tool_result")?.(
		{ toolName: "write", input: { path: file }, isError: false, content: [{ type: "text", text: "written" }] },
		ctx,
	)) as { content?: { text: string }[] } | undefined;
	return (res?.content ?? []).map((c) => c.text).join("\n");
}

let nvim: ChildProcess;

async function until(what: string, check: () => boolean | Promise<boolean>, timeoutMs = 60_000) {
	const t0 = Date.now();
	while (Date.now() - t0 < timeoutMs) {
		if (await check()) return;
		await new Promise((r) => setTimeout(r, 200));
	}
	throw new Error(`timed out waiting for ${what}`);
}

describe("nvim LSP bridge", () => {
	beforeAll(async () => {
		fixtures();
		const tsls = execFileSync(
			"nix",
			["build", "--no-link", "--print-out-paths", "nixpkgs#typescript-language-server", "nixpkgs#typescript"],
			{ encoding: "utf8" },
		)
			.trim()
			.split("\n")
			.map((p) => `${p}/bin`);
		const cfg = path.join(ROOT, "config");
		fs.mkdirSync(cfg);
		fs.symlinkSync(NVIM_CONFIG, path.join(cfg, "nvim"));

		nvimBridge(pi as never);
		handlers.get("session_start")?.({}, ctx);

		nvim = spawn("nvim", ["--headless", "--listen", SOCK], {
			cwd: PROJECT,
			stdio: "ignore",
			env: {
				...process.env,
				XDG_CONFIG_HOME: cfg,
				XDG_STATE_HOME: path.join(ROOT, "state"),
				XDG_CACHE_HOME: path.join(ROOT, "cache"),
				PATH: [...tsls, process.env.PATH].join(":"),
			},
		});
		await until("nvim to connect", async () => !(await lsp({ action: "status" })).startsWith("No nvim"));
	}, 180_000);

	afterAll(async () => {
		if (nvim && nvim.exitCode === null) {
			const { promise, resolve } = Promise.withResolvers();
			nvim.once("exit", resolve);
			nvim.kill();
			await promise;
		}
		handlers.get("session_shutdown")?.({}, ctx);
		// Language servers nvim started may still be flushing their logs there.
		fs.rmSync(ROOT, { recursive: true, force: true, maxRetries: 10 });
	});

	it("answers without an nvim for paths outside nvim's cwd", async () => {
		assert.match(await lsp({ action: "hover", file: "/etc/hostname", line: 1 }), /^No nvim serves/);
	});

	it("rust: finds a definition in a file nvim never opened", { timeout: 120_000 }, async () => {
		const out = await lsp({ action: "definition", file: "rs/src/main.rs", line: 8, symbol: "add", timeout: 90 });
		assert.match(out, /rs\/src\/main\.rs:3:4/, out);
	});

	it("keeps files loaded for omp out of the buffer list", () => {
		const listed = lua('vim.tbl_map(function(b) return b.name end, vim.fn.getbufinfo({ buflisted = 1 }))');
		assert.notInclude(listed, "main.rs");
	});

	it("rust: an edit reports the compiler's errors, through the check a save triggers", { timeout: 120_000 }, async () => {
		const out = await omp_write(
			"rs/src/main.rs",
			"mod util;\n\nfn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\nfn main() {\n    let x: String = add(1, util::two());\n    println!(\"{x}\");\n}\n",
		);
		assert.match(out, /rs\/src\/main\.rs: \d+ diagnostic/, out);
		assert.match(out, /8:\d+ error .*(mismatched types|expected `?String`?)/, out);
		// Only the save-triggered check (cargo clippy) reports as rustc.
		assert.match(out, /\[rustc/, out);
	});

	it("rust: errors a changed signature causes in another file", { timeout: 120_000 }, async () => {
		await omp_write(
			"rs/src/main.rs",
			"mod util;\n\nfn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\nfn main() {\n    let x = add(1, util::two());\n    println!(\"{x}\");\n}\n",
		);
		const out = await omp_write("rs/src/util.rs", "pub fn two() -> String {\n    String::new()\n}\n");
		assert.match(out, /Errors in other files since this change:\nrs\/src\/main\.rs:/, out);
		await omp_write("rs/src/util.rs", "pub fn two() -> i32 {\n    2\n}\n");
	});

	it("rust: renames across the workspace and saves the files", { timeout: 60_000 }, async () => {
		const out = await lsp({ action: "rename", file: "rs/src/main.rs", line: 3, symbol: "add", new_name: "sum" });
		assert.match(out, /Applied rename:/, out);
		const main = fs.readFileSync(path.join(PROJECT, "rs/src/main.rs"), "utf8");
		assert.include(main, "fn sum(a: i32");
		assert.include(main, "let x = sum(1");
	});

	it("ts: an edit reports the type error", { timeout: 60_000 }, async () => {
		const out = await omp_write("ts/src/b.ts", 'import { add } from "./a.js";\nexport const x: boolean = add(1, 2);\n');
		assert.match(out, /ts\/src\/b\.ts: 1 diagnostic/, out);
		assert.match(out, /2:\d+ error .*not assignable to type 'boolean'/, out);
	});

	it("ts: diagnostics clear once the error is fixed", { timeout: 60_000 }, async () => {
		const out = await omp_write("ts/src/b.ts", 'import { add } from "./a.js";\nexport const x: number = add(1, 2);\n');
		assert.match(out, /ts\/src\/b\.ts: OK/, out);
	});

	it("ts: references across files", { timeout: 60_000 }, async () => {
		const out = await lsp({ action: "references", file: "ts/src/a.ts", line: 1, symbol: "add" });
		assert.match(out, /ts\/src\/a\.ts:1:17/, out);
		assert.match(out, /ts\/src\/b\.ts:2:26/, out);
	});

	it("ts: hover", { timeout: 60_000 }, async () => {
		const out = await lsp({ action: "hover", file: "ts/src/b.ts", line: 2, symbol: "add" });
		assert.match(out, /add\(a: number, b: number\): number/, out);
	});

	it("leaves a buffer with unsaved changes alone", { timeout: 60_000 }, async () => {
		const file = path.join(PROJECT, "ts/src/b.ts");
		lua(
			`(function() vim.cmd.edit("${file}"); vim.api.nvim_buf_set_lines(0, 1, 2, false, { "export const x: number = 3;" }); return 1 end)()`,
		);
		const out = await omp_write("ts/src/b.ts", 'import { add } from "./a.js";\nexport const y: number = add(1, 2);\n');
		assert.match(out, /unsaved changes/, out);
		assert.equal(lua("vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]"), "export const x: number = 3;");
		lua('(function() vim.cmd("edit!"); vim.cmd.enew(); return 1 end)()');
	});

	it("adds nothing after editing a file no server handles, and quickly", async () => {
		const t0 = Date.now();
		assert.equal(await omp_write("README.md", "# fixture\n\nmore\n"), "");
		assert.isBelow(Date.now() - t0, 2000);
	});

	it("keeps nvim responsive while waiting on diagnostics", { timeout: 60_000 }, async () => {
		const pending = omp_write("rs/src/util.rs", "pub fn two() -> i32 {\n    3\n}\n");
		await until("nvim to work on the edit", () => lua("require('omp-lsp').inflight()") !== "0", 10_000);
		const t0 = Date.now();
		assert.equal(lua("1 + 1"), "2");
		assert.isBelow(Date.now() - t0, 500);
		await pending;
	});
});
