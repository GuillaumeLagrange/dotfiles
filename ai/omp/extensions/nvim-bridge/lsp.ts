// omp's `lsp` tool and its diagnostics after edits, served by the LSP clients of an nvim working
// on the same project: omp runs no language server of its own (`lsp.enabled: false`). nvim
// (nvim/lua/omp-lsp/) connects to this session's bridge socket, sends `{"op":"lsp_provide"}`,
// and answers the requests sent back on that connection. No nvim, no LSP.

import fs from "node:fs";
import type net from "node:net";
import path from "node:path";

type Text = { type: "text"; text: string };
type ToolResult = { content: Text[]; details?: unknown };
type Ctx = { cwd?: string };
type Schema = {
	describe: (text: string) => Schema;
	optional: () => Schema;
};
type Z = {
	object: (shape: Record<string, unknown>) => unknown;
	string: () => Schema;
	number: () => Schema;
	boolean: () => Schema;
	enum: (values: readonly string[]) => Schema;
};
export type LspPi = {
	on: (event: string, handler: (event: never, ctx: Ctx) => unknown) => void;
	zod: Z;
	registerTool: (tool: {
		name: string;
		label: string;
		description: string;
		parameters: unknown;
		execute: (
			id: string,
			params: Params,
			signal: AbortSignal | undefined,
			onUpdate: unknown,
			ctx: Ctx,
		) => Promise<ToolResult>;
	}) => void;
};

const ACTIONS = [
	"diagnostics",
	"definition",
	"type_definition",
	"implementation",
	"references",
	"hover",
	"symbols",
	"rename",
	"rename_file",
	"code_actions",
	"status",
	"reload",
	"capabilities",
	"request",
] as const;

type Params = {
	action: (typeof ACTIONS)[number];
	file?: string;
	line?: number;
	symbol?: string;
	query?: string;
	new_name?: string;
	apply?: boolean;
	timeout?: number;
	payload?: string;
};

/** How long an edit waits for the diagnostics its save triggers (e.g. rust-analyzer's check). */
export const EDIT_BUDGET_MS = Number(process.env.OMP_NVIM_LSP_EDIT_BUDGET_MS ?? 10_000);
const MAX_GLOB_FILES = 20;
const MAX_REFERENCE_CONTEXT = 50;
const MAX_WORKSPACE_SYMBOLS = 200;

type Pending = { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: NodeJS.Timeout };
type Provider = { sock: net.Socket; pid: number; cwd: string; since: number; pending: Map<number, Pending> };

// Module-level: subagents of this omp run their own copy of the extension in this process and
// reach the nvims through the same connections.
const providers = new Set<Provider>();
let nextId = 1;

const within = (dir: string, file: string) => file === dir || file.startsWith(dir.endsWith("/") ? dir : `${dir}/`);

/**
 * The nvim for `target`: among those whose cwd holds it, the closest one; failing that, one
 * working inside it (omp's cwd above nvim's). The latest to connect wins a tie.
 */
function pick(target: string): Provider | undefined {
	let best: Provider | undefined;
	let bestScore = -1;
	for (const p of providers) {
		const score = within(p.cwd, target) ? p.cwd.length : within(target, p.cwd) ? 0 : -1;
		if (score > bestScore || (score === bestScore && score >= 0 && best && p.since > best.since)) {
			best = p;
			bestScore = score;
		}
	}
	return bestScore >= 0 ? best : undefined;
}

/** A bridge connection on which nvim just announced itself. */
export function addProvider(sock: net.Socket, msg: { pid?: unknown; cwd?: unknown }): void {
	const provider: Provider = {
		sock,
		pid: Number(msg.pid),
		cwd: String(msg.cwd ?? "/"),
		since: Date.now(),
		pending: new Map(),
	};
	providers.add(provider);
	sock.on("close", () => {
		providers.delete(provider);
		for (const p of provider.pending.values()) {
			clearTimeout(p.timer);
			p.reject(new Error("nvim disconnected"));
		}
		provider.pending.clear();
	});
}

export function isProvider(sock: net.Socket): boolean {
	for (const p of providers) if (p.sock === sock) return true;
	return false;
}

/** A line nvim sent on its provider connection: the answer to one of our requests. */
export function handleReply(sock: net.Socket, msg: { id?: unknown; result?: unknown; error?: unknown }): void {
	for (const p of providers) {
		if (p.sock !== sock) continue;
		const pending = p.pending.get(Number(msg.id));
		if (!pending) return;
		p.pending.delete(Number(msg.id));
		clearTimeout(pending.timer);
		if (msg.error !== undefined && msg.error !== null) pending.reject(new Error(String(msg.error)));
		else pending.resolve(msg.result);
	}
}

function call<T>(p: Provider, method: string, params: object, timeoutMs: number, signal?: AbortSignal): Promise<T> {
	const id = nextId++;
	const { promise, resolve, reject } = Promise.withResolvers<T>();
	const timer = setTimeout(() => {
		p.pending.delete(id);
		reject(new Error(`nvim did not answer ${method} within ${Math.round(timeoutMs / 1000)}s`));
	}, timeoutMs);
	p.pending.set(id, { resolve: resolve as (v: unknown) => void, reject, timer });
	signal?.addEventListener(
		"abort",
		() => {
			p.pending.delete(id);
			clearTimeout(timer);
			reject(new Error("aborted"));
		},
		{ once: true },
	);
	p.sock.write(`${JSON.stringify({ id, method, params })}\n`);
	return promise;
}

// Lua encodes an empty table as `{}`: lists may come back as objects.
const list = <T>(v: unknown): T[] => (Array.isArray(v) ? (v as T[]) : []);

type Diagnostic = { line: number; col: number; severity: string; message: string; source?: string; code?: string };
type FileDiagnostics = { file: string; state?: string; error?: string; diagnostics?: Diagnostic[] };
type CheckResult = {
	files?: FileDiagnostics[];
	notes?: string[];
	timed_out?: boolean;
	still_running?: string[];
	elsewhere?: FileDiagnostics[];
};
type Location = { file: string; line: number; col: number; text?: string };
type SymbolInfo = {
	name: string;
	kind: string;
	detail?: string;
	container?: string;
	file?: string;
	line?: number;
	children?: SymbolInfo[];
};
type EditSummary = {
	files?: { file: string; edits?: { line: number; old?: string; new: string }[] }[];
	operations?: string[];
};

function formatDiagnostics(diags: Diagnostic[], indent = "  "): string[] {
	return diags.map((d) => {
		const tag = [d.source, d.code].filter(Boolean).join(" ");
		const message = d.message.replace(/\s*\n\s*/g, " / ");
		return `${indent}${d.line}:${d.col} ${d.severity}${tag ? ` [${tag}]` : ""} ${message}`;
	});
}

function formatEdit(summary: EditSummary | undefined, rel: (f: string) => string): string[] {
	const out: string[] = [];
	for (const f of list<NonNullable<EditSummary["files"]>[number]>(summary?.files)) {
		const edits = list<{ line: number; old?: string; new: string }>(f.edits);
		out.push(`  ${rel(f.file)}: ${edits.length} edit(s)`);
		for (const e of edits.slice(0, 10)) {
			out.push(`    ${e.line}: ${JSON.stringify(e.new)}${e.old !== undefined ? ` (was: ${e.old.trim()})` : ""}`);
		}
		if (edits.length > 10) out.push(`    … ${edits.length - 10} more`);
	}
	for (const op of list<string>(summary?.operations)) out.push(`  ${op}`);
	return out;
}

function formatSymbols(symbols: SymbolInfo[], rel: (f: string) => string, depth = 0, withFile = false): string[] {
	const out: string[] = [];
	for (const s of symbols) {
		const where = withFile && s.file ? ` @ ${rel(s.file)}:${s.line ?? "?"}` : s.line ? ` @ ${s.line}` : "";
		const container = s.container ? ` (in ${s.container})` : "";
		out.push(`${"  ".repeat(depth)}${s.kind} ${s.name}${container}${where}`);
		out.push(...formatSymbols(list<SymbolInfo>(s.children), rel, depth + 1, withFile));
	}
	return out;
}

function formatCheck(res: CheckResult, rel: (f: string) => string, budgetMs: number): string {
	const lines: string[] = [];
	for (const f of list<FileDiagnostics>(res.files)) {
		if (f.error) {
			lines.push(`${rel(f.file)}: ${f.error}`);
			continue;
		}
		const diags = list<Diagnostic>(f.diagnostics);
		if (diags.length === 0) lines.push(`${rel(f.file)}: OK`);
		else lines.push(`${rel(f.file)}: ${diags.length} diagnostic(s)`, ...formatDiagnostics(diags));
	}
	const elsewhere = list<FileDiagnostics>(res.elsewhere);
	if (elsewhere.length > 0) {
		lines.push("Errors in other files since this change:");
		for (const f of elsewhere) lines.push(`${rel(f.file)}:`, ...formatDiagnostics(list<Diagnostic>(f.diagnostics)));
	}
	for (const note of list<string>(res.notes)) lines.push(`Note: ${note}`);
	if (res.timed_out) {
		const running = list<string>(res.still_running);
		lines.push(
			`Note: language servers still busy after ${Math.round(budgetMs / 1000)}s${running.length ? ` (${running.join(", ")})` : ""}: diagnostics may be incomplete.`,
		);
	}
	return lines.join("\n");
}

const text = (t: string): ToolResult => ({ content: [{ type: "text", text: t }] });

/** Paths a mutating tool call touched, from the hook's normalized input. */
function touchedPaths(input: unknown, cwd: string): string[] {
	if (!input || typeof input !== "object") return [];
	const rec = input as Record<string, unknown>;
	const raw: unknown[] = [];
	if (typeof rec.path === "string") raw.push(rec.path);
	if (Array.isArray(rec.paths)) raw.push(...rec.paths);
	const out = new Set<string>();
	for (const p of raw) {
		if (typeof p !== "string" || p === "" || /^[a-z]+:\/\//.test(p)) continue;
		const abs = path.resolve(cwd, p);
		try {
			if (fs.statSync(abs).isFile()) out.add(abs);
		} catch {}
	}
	return [...out];
}

const EDIT_TOOLS: Record<string, true> = { edit: true, write: true, ast_edit: true };
// Tools that may change files without saying which.
const SHELL_TOOLS: Record<string, true> = { bash: true, eval: true };

export function registerLsp(pi: LspPi): void {
	const z = pi.zod;

	pi.registerTool({
		name: "lsp",
		label: "LSP",
		description: [
			"Query the language servers of the nvim working on this project (rust-analyzer, ts_ls, …): diagnostics,",
			"navigation, symbols, renames, code actions. nvim owns the servers; answers reflect what nvim shows,",
			"including unsaved nvim buffers (flagged). Positions: 1-based `line` plus `symbol` (text on that line,",
			"`name#N` for its Nth occurrence).",
			"- diagnostics: `file` (path, glob, or `*` for every file nvim has diagnostics for).",
			"- definition | type_definition | implementation | references | hover: `file`, `line`, `symbol`.",
			"- symbols: `file` for its outline, or `file: \"*\"` + `query` to search the workspace.",
			"- rename: `file`, `line`, `symbol`, `new_name`; applies unless `apply: false`.",
			"- rename_file: `file` → `new_name` (path), updating imports; applies unless `apply: false`.",
			"- code_actions: `file`, `line`, `symbol`; lists them, or applies one with `apply: true` and `query`",
			"  (index or title substring).",
			"- status | capabilities | reload: optional `file`.",
			"- request: raw LSP method in `query`, params as JSON in `payload` (else built from file/line/symbol).",
		].join("\n"),
		parameters: z.object({
			action: z.enum(ACTIONS).describe("What to do"),
			file: z.string().optional().describe("File path, glob (diagnostics), or `*` (workspace)"),
			line: z.number().optional().describe("1-based line"),
			symbol: z.string().optional().describe("Text on `line` to position on; `name#N` for its Nth occurrence"),
			query: z.string().optional().describe("Workspace symbol query, code action selector, or raw LSP method"),
			new_name: z.string().optional().describe("New name (rename) or destination path (rename_file)"),
			apply: z.boolean().optional().describe("rename/rename_file: false previews; code_actions: true applies"),
			timeout: z.number().optional().describe("Seconds, default 20, 5..300"),
			payload: z.string().optional().describe("JSON params for `request`"),
		}),
		async execute(_id, params, signal, _onUpdate, ctx) {
			const cwd = ctx?.cwd ?? process.cwd();
			const rel = (f: string) => (within(cwd, f) ? path.relative(cwd, f) || "." : f);
			const timeoutMs = Math.min(Math.max(params.timeout ?? 20, 5), 300) * 1000;
			const file = params.file && params.file !== "*" ? path.resolve(cwd, params.file) : undefined;
			const target = file ?? cwd;
			const provider = pick(target);
			if (!provider) {
				return text(
					`No nvim serves ${rel(target)}: the LSP runs in nvim, and none is connected to this omp for that path. Open nvim in this project (it connects on its own).`,
				);
			}
			// nvim gets the budget; we wait a bit longer for its answer.
			const ask = <T>(method: string, p: object) =>
				call<T>(provider, method, { root: cwd, budget_ms: timeoutMs, ...p }, timeoutMs + 5000, signal);
			const pos = { file, line: params.line, symbol: params.symbol };
			try {
				switch (params.action) {
					case "diagnostics": {
						if (!params.file) return text("diagnostics needs `file`: a path, a glob, or `*`.");
						if (params.file === "*") {
							const res = await ask<CheckResult>("workspace_diagnostics", {});
							const files = list<FileDiagnostics>(res.files);
							if (files.length === 0) return text("No diagnostics in nvim for this workspace.");
							return text(files.map((f) => [`${rel(f.file)}:`, ...formatDiagnostics(list<Diagnostic>(f.diagnostics))].join("\n")).join("\n"));
						}
						let files = [path.resolve(cwd, params.file)];
						let truncated = 0;
						if (/[*?[{]/.test(params.file)) {
							const matches = fs.globSync(params.file, { cwd }).map((f) => path.resolve(cwd, f));
							truncated = Math.max(matches.length - MAX_GLOB_FILES, 0);
							files = matches.slice(0, MAX_GLOB_FILES);
							if (files.length === 0) return text(`No file matches ${params.file}.`);
						}
						const res = await ask<CheckResult>("diagnostics", { files });
						const out = formatCheck(res, rel, timeoutMs);
						return text(truncated ? `Only the first ${MAX_GLOB_FILES} matches (${truncated} more skipped).\n${out}` : out);
					}
					case "definition":
					case "type_definition":
					case "implementation":
					case "references": {
						if (!file) return text(`${params.action} needs \`file\`.`);
						const res = await ask<{ locations?: Location[]; errors?: string[]; note?: string }>("locations", {
							...pos,
							kind: params.action,
						});
						const locs = list<Location>(res.locations);
						const noun = params.action === "references" ? "reference" : params.action.replace("_", " ");
						const lines: string[] = [];
						if (res.note) lines.push(`Note: ${res.note}`);
						if (locs.length === 0) lines.push(`No ${noun} found`);
						else {
							lines.push(`Found ${locs.length} ${noun}(s):`);
							locs.forEach((l, i) => {
								const ctxText = l.text && i < MAX_REFERENCE_CONTEXT ? `  ${l.text}` : "";
								lines.push(`${rel(l.file)}:${l.line}:${l.col}${ctxText}`);
							});
						}
						for (const e of list<string>(res.errors)) lines.push(`Error: ${e}`);
						return text(lines.join("\n"));
					}
					case "hover": {
						if (!file) return text("hover needs `file`.");
						const res = await ask<{ hover?: string[]; errors?: string[]; note?: string }>("hover", pos);
						const hovers = list<string>(res.hover);
						const lines = [res.note ? `Note: ${res.note}` : "", hovers.length ? hovers.join("\n\n---\n\n") : "No hover information"];
						for (const e of list<string>(res.errors)) lines.push(`Error: ${e}`);
						return text(lines.filter(Boolean).join("\n"));
					}
					case "symbols": {
						if (params.file === "*") {
							if (!params.query) return text("Workspace symbols need `query`.");
							const res = await ask<{ symbols?: SymbolInfo[]; errors?: string[] }>("workspace_symbols", {
								query: params.query,
							});
							const q = params.query.toLowerCase();
							const seen = new Set<string>();
							const syms = list<SymbolInfo>(res.symbols).filter((s) => {
								const key = `${s.name}@${s.file}:${s.line}`;
								if (seen.has(key) || !s.name.toLowerCase().includes(q)) return false;
								seen.add(key);
								return true;
							});
							const lines = [`Found ${syms.length} symbol(s) matching "${params.query}":`];
							lines.push(...formatSymbols(syms.slice(0, MAX_WORKSPACE_SYMBOLS), rel, 0, true));
							if (syms.length > MAX_WORKSPACE_SYMBOLS) lines.push(`… ${syms.length - MAX_WORKSPACE_SYMBOLS} more`);
							for (const e of list<string>(res.errors)) lines.push(`Error: ${e}`);
							return text(lines.join("\n"));
						}
						if (!file) return text("symbols needs `file`, or `file: \"*\"` with `query`.");
						const res = await ask<{ symbols?: SymbolInfo[]; errors?: string[]; note?: string }>("document_symbols", {
							file,
						});
						const syms = list<SymbolInfo>(res.symbols);
						const lines = [res.note ? `Note: ${res.note}` : "", `Symbols in ${rel(file)}:`, ...formatSymbols(syms, rel)];
						if (syms.length === 0) lines.push("  (none)");
						for (const e of list<string>(res.errors)) lines.push(`Error: ${e}`);
						return text(lines.filter(Boolean).join("\n"));
					}
					case "rename": {
						if (!file || !params.new_name) return text("rename needs `file` and `new_name`.");
						const res = await ask<{
							empty?: boolean;
							preview?: EditSummary;
							applied?: EditSummary;
							written?: string[];
							unsaved?: string[];
							note?: string;
						}>("rename", { ...pos, new_name: params.new_name, apply: params.apply !== false });
						if (res.empty) return text("Rename returned no edits");
						if (res.preview) return text(["Rename preview:", ...formatEdit(res.preview, rel), res.note ? `Note: ${res.note}` : ""].filter(Boolean).join("\n"));
						return text(["Applied rename:", ...formatEdit(res.applied, rel), ...writtenLines(res.written, res.unsaved, rel)].join("\n"));
					}
					case "rename_file": {
						if (!file || !params.new_name) return text("rename_file needs `file` and `new_name`.");
						const dest = path.resolve(cwd, params.new_name);
						const res = await ask<{
							preview?: EditSummary[];
							applied?: EditSummary[];
							written?: string[];
							unsaved?: string[];
							errors?: string[];
						}>("rename_file", { file, new_name: dest, apply: params.apply !== false });
						const edits = list<EditSummary>(res.preview ?? res.applied);
						const head = res.preview ? `Rename preview: ${rel(file)} → ${rel(dest)}` : `Renamed ${rel(file)} → ${rel(dest)}`;
						const lines = [head, ...edits.flatMap((e) => formatEdit(e, rel))];
						if (!res.preview) lines.push(...writtenLines(res.written, res.unsaved, rel));
						for (const e of list<string>(res.errors)) lines.push(`Note: ${e}`);
						return text(lines.join("\n"));
					}
					case "code_actions": {
						if (!file) return text("code_actions needs `file`.");
						const res = await ask<{
							actions?: { title: string; kind?: string; client: string }[];
							no_match?: string;
							applied?: string;
							edit?: EditSummary;
							command?: string;
							command_error?: string;
							written?: string[];
							unsaved?: string[];
							errors?: string[];
							note?: string;
						}>("code_actions", { ...pos, query: params.query, apply: params.apply === true });
						if (res.applied !== undefined) {
							const lines = [`Applied "${res.applied}":`];
							if (res.edit) lines.push("Workspace edit:", ...formatEdit(res.edit, rel));
							if (res.command) lines.push(`Executed command: ${res.command}${res.command_error ? ` (failed: ${res.command_error})` : ""}`);
							lines.push(...writtenLines(res.written, res.unsaved, rel));
							return text(lines.join("\n"));
						}
						const actions = list<{ title: string; kind?: string; client: string }>(res.actions);
						const lines: string[] = [];
						if (res.no_match) lines.push(`No code action matches "${res.no_match}". Available actions:`);
						else lines.push(`${actions.length} code action(s):`);
						actions.forEach((a, i) => lines.push(`${i}: [${a.kind ?? "action"}] ${a.title}`));
						if (res.note) lines.push(`Note: ${res.note}`);
						for (const e of list<string>(res.errors)) lines.push(`Error: ${e}`);
						return text(lines.join("\n"));
					}
					case "status": {
						const res = await ask<{ cwd: string; clients?: { name: string; root?: string; buffers: number; busy?: string[] }[] }>(
							"status",
							{},
						);
						const clients = list<{ name: string; root?: string; buffers: number; busy?: string[] }>(res.clients);
						const lines = [`nvim pid ${provider.pid}, cwd ${res.cwd}`];
						if (clients.length === 0) lines.push("No language server running for this project yet (they start when nvim opens a file).");
						for (const c of clients) {
							const busy = list<string>(c.busy);
							lines.push(`${c.name}: root ${c.root ?? "?"}, ${c.buffers} buffer(s)${busy.length ? `, busy: ${busy.join(", ")}` : ""}`);
						}
						return text(lines.join("\n"));
					}
					case "capabilities": {
						const res = await ask<{ clients?: { name: string; capabilities: unknown }[] }>("capabilities", { file });
						const clients = list<{ name: string; capabilities: unknown }>(res.clients);
						if (clients.length === 0) return text("No language server.");
						return text(clients.map((c) => `${c.name}:\n${JSON.stringify(c.capabilities, null, 2)}`).join("\n\n"));
					}
					case "reload": {
						const res = await ask<{ restarted?: string[] }>("reload", { file });
						const names = list<string>(res.restarted);
						return text(names.length ? names.map((n) => `Restarted ${n}`).join("\n") : "No language server to restart.");
					}
					case "request": {
						if (!params.query) return text("request needs the LSP method in `query`.");
						let payload: unknown;
						if (params.payload) {
							try {
								payload = JSON.parse(params.payload);
							} catch (err) {
								return text(`Invalid JSON in payload: ${err}`);
							}
						}
						const res = await ask<{ client: string; result: unknown }>("request", {
							...pos,
							method: params.query,
							params: payload,
						});
						const body = typeof res.result === "string" ? res.result : JSON.stringify(res.result ?? null, null, 2);
						return text(`${res.client} ← ${params.query}:\n${body}`);
					}
				}
			} catch (err) {
				return text(`LSP error (via nvim ${provider.pid}): ${err instanceof Error ? err.message : String(err)}`);
			}
		},
	});

	pi.on("tool_result", async (event: { toolName: string; input?: unknown; isError?: boolean; content?: Text[] }, ctx) => {
		if (event.isError) return;
		const cwd = ctx?.cwd ?? process.cwd();
		if (SHELL_TOOLS[event.toolName]) {
			const provider = pick(cwd);
			if (provider) await call(provider, "refresh", { root: cwd }, 5000).catch(() => {});
			return;
		}
		if (!EDIT_TOOLS[event.toolName]) return;
		const files = touchedPaths(event.input, cwd);
		if (files.length === 0) return;
		const groups = new Map<Provider, string[]>();
		for (const f of files) {
			const p = pick(f);
			if (p) groups.set(p, [...(groups.get(p) ?? []), f]);
		}
		if (groups.size === 0) return;
		const rel = (f: string) => (within(cwd, f) ? path.relative(cwd, f) : f);
		const reports: string[] = [];
		await Promise.all(
			[...groups].map(async ([p, group]) => {
				try {
					const res = await call<CheckResult>(p, "edited", { files: group, root: cwd, budget_ms: EDIT_BUDGET_MS }, EDIT_BUDGET_MS + 5000);
					const report = formatCheck(res, rel, EDIT_BUDGET_MS);
					if (report) reports.push(report);
				} catch (err) {
					reports.push(`nvim LSP unavailable: ${err instanceof Error ? err.message : String(err)}`);
				}
			}),
		);
		if (reports.length === 0) return;
		return { content: [...(event.content ?? []), { type: "text", text: `\nLSP diagnostics (nvim):\n${reports.join("\n")}` }] };
	});
}

function writtenLines(written: unknown, unsaved: unknown, rel: (f: string) => string): string[] {
	const out: string[] = [];
	const w = list<string>(written);
	const u = list<string>(unsaved);
	if (w.length) out.push(`Saved by nvim: ${w.map(rel).join(", ")}`);
	if (u.length) out.push(`Left unsaved in nvim (it had unsaved changes there): ${u.map(rel).join(", ")}`);
	return out;
}
