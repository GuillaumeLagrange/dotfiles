// Names an omp started by the `omp-fixit` CLI (modules/headless/omp-fixit.sh) after what it works
// on. OMP_FIXIT holds the task's name: the session is titled with it from the start, and the
// `fixit_title` tool appends a short summary once the agent knows what the task is about, to the
// session title (what omp-panel shows) and to the zellij tab.
//
// Fixit omps sharing a repo take turns: a tool only runs while its omp holds the repo's lock, an
// flock held by a child process from the first tool call of a turn until the turn ends (or omp
// dies). A blocked agent calls `fixit_lock` to wait for its turn.

import { type ChildProcess, execFile, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

type Ctx = { hasUI?: boolean; cwd?: string; agent?: { kind?: string } };
type ToolResult = { content: { type: "text"; text: string }[] };
type Z = {
	object: (shape: Record<string, unknown>) => unknown;
	string: () => { describe: (text: string) => unknown };
};
type Pi = {
	on: (event: string, handler: (event: never, ctx: Ctx) => unknown) => void;
	zod: Z;
	getSessionName: () => string | undefined;
	setSessionName: (name: string) => Promise<void>;
	registerTool: <P>(tool: {
		name: string;
		label: string;
		description: string;
		parameters: unknown;
		loadMode?: "discoverable" | "essential";
		execute: (
			id: string,
			params: P,
			signal: AbortSignal | undefined,
			onUpdate: ((update: ToolResult) => void) | undefined,
			ctx: Ctx,
		) => Promise<ToolResult>;
	}) => void;
};

const run = promisify(execFile);

async function renameTab(name: string): Promise<void> {
	const pane = Number.parseInt(process.env.ZELLIJ_PANE_ID ?? "", 10);
	if (!process.env.ZELLIJ_SESSION_NAME || !Number.isFinite(pane)) return;
	const panes: { id: number; is_plugin: boolean; tab_id: number }[] = JSON.parse(
		(await run("zellij", ["action", "list-panes", "--json"])).stdout,
	);
	const own = panes.find((p) => !p.is_plugin && p.id === pane);
	if (own) await run("zellij", ["action", "rename-tab", "--tab-id", String(own.tab_id), name]);
}

const text = (t: string): ToolResult => ({ content: [{ type: "text", text: t }] });

const repos = new Map<string, Promise<string>>();
function repoOf(cwd: string): Promise<string> {
	let repo = repos.get(cwd);
	if (!repo) {
		repo = run("git", ["-C", cwd, "rev-parse", "--show-toplevel"]).then(
			(r) => r.stdout.trim(),
			() => cwd,
		);
		repos.set(cwd, repo);
	}
	return repo;
}

function lockFile(repo: string): string {
	const state = process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local", "state");
	const dir = process.env.OMP_FIXIT_LOCK_DIR || path.join(state, "omp-fixit", "locks");
	return path.join(dir, `${repo.replaceAll("/", "%")}.lock`);
}

type Holder = { pid: number; name: string };
function holderOf(file: string): Holder | undefined {
	try {
		return JSON.parse(fs.readFileSync(`${file}.holder`, "utf8"));
	} catch {
		return undefined;
	}
}

// Resolves with the child holding the flock, or undefined if busy (`wait` false) or aborted.
// The child keeps it until its stdin closes: on release, or when omp dies.
async function take(file: string, wait: boolean, signal?: AbortSignal): Promise<ChildProcess | undefined> {
	if (signal?.aborted) return undefined;
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const { promise, resolve, reject } = Promise.withResolvers<ChildProcess | undefined>();
	const child = spawn("flock", [...(wait ? [] : ["-n"]), file, "-c", "echo; exec cat"], {
		stdio: ["pipe", "pipe", "ignore"],
	});
	const abort = () => {
		child.stdin?.end();
		child.kill();
	};
	signal?.addEventListener("abort", abort, { once: true });
	child.stdout?.once("data", () => resolve(child));
	child.once("exit", () => resolve(undefined));
	child.once("error", reject);
	try {
		return await promise;
	} finally {
		signal?.removeEventListener("abort", abort);
	}
}

// Process-wide: subagents run in their main agent's process and share its lock.
let held: { file: string; child: ChildProcess } | undefined;
let trying: Promise<unknown> | undefined;
const heldBefore = new Set<string>();

function release(): void {
	held?.child.stdin?.end();
	held = undefined;
}

// `context` warns the agent when another fixit omp worked in the repo since its last turn.
async function acquire(
	file: string,
	name: string,
	wait: boolean,
	signal?: AbortSignal,
): Promise<{ ok: boolean; context?: string }> {
	while (trying) await trying.catch(() => {});
	if (held?.file === file) return { ok: true };
	release();
	const attempt = take(file, wait, signal);
	if (!wait) trying = attempt;
	let child: ChildProcess | undefined;
	try {
		child = await attempt;
	} finally {
		if (trying === attempt) trying = undefined;
	}
	if (!child) return { ok: false };
	if (held?.file === file) {
		child.stdin?.end();
		return { ok: true };
	}
	release();
	const own = child;
	held = { file, child: own };
	own.once("exit", () => {
		if (held?.child === own) held = undefined;
	});
	const prev = holderOf(file);
	fs.writeFileSync(`${file}.holder`, JSON.stringify({ pid: process.pid, name } satisfies Holder));
	const back = heldBefore.has(file);
	heldBefore.add(file);
	if (back && prev && prev.pid !== process.pid) {
		return {
			ok: true,
			context:
				`Fixit omp \`${prev.name}\` worked in this repo since your last turn: re-read files before ` +
				"editing them, and leave its changes alone.",
		};
	}
	return { ok: true };
}

const NOTE =
	"Other fixit omps may work in this repo at the same time. They take turns through a lock on the " +
	"repo: your first tool call of a turn takes it, the end of your turn releases it. When a tool is " +
	"blocked because another omp holds it, call `fixit_lock` to wait for your turn instead of working " +
	"around it. Between your turns the repo may change: changes you did not make belong to other " +
	"omps. Never revert, stash, reformat, or commit them; stage and commit only your own hunks.";

const OWN_TOOLS: Record<string, true> = { fixit_title: true, fixit_lock: true };

export default function fixit(pi: Pi) {
	const base = process.env.OMP_FIXIT;
	// OMPCODE: an omp run from one of this omp's shells inherits the variable.
	if (!base || process.env.OMPCODE === "1") return;
	const isSub = (ctx: Ctx) => ctx?.agent?.kind === "sub";

	pi.on("session_start", async (_event, ctx) => {
		if (ctx?.hasUI === true && !isSub(ctx) && !pi.getSessionName()) await pi.setSessionName(base);
	});

	pi.on("before_agent_start", (event: { systemPrompt: string[] }, ctx) => {
		if (isSub(ctx)) return;
		return { systemPrompt: [...event.systemPrompt, NOTE] };
	});

	pi.on("tool_call", async (event: { toolName: string; input?: { path?: unknown } }, ctx) => {
		// Discoverable tools are reached through `read`/`write` on `xd://<tool>`.
		const target = event.input?.path;
		if (OWN_TOOLS[event.toolName] || (typeof target === "string" && target.startsWith("xd://fixit_"))) return;
		const repo = await repoOf(ctx.cwd ?? process.cwd());
		const file = lockFile(repo);
		const { ok, context } = await acquire(file, pi.getSessionName() ?? base, false);
		if (ok) return context ? { additionalContext: context } : undefined;
		const holder = holderOf(file)?.name ?? "another fixit omp";
		return {
			block: true,
			reason: `Fixit omp \`${holder}\` is working in ${repo} and holds its lock. Call \`fixit_lock\` to wait for your turn.`,
		};
	});

	pi.on("agent_end", (_event, ctx) => {
		if (!isSub(ctx)) release();
	});
	pi.on("session_shutdown", (_event, ctx) => {
		if (!isSub(ctx)) release();
	});

	pi.registerTool<Record<string, never>>({
		name: "fixit_lock",
		label: "Fixit Lock",
		description:
			"Wait until no other fixit omp works in this repo, then take its lock for the rest of your " +
			"turn. Call it when a tool is blocked because another fixit omp holds the lock.",
		parameters: pi.zod.object({}),
		loadMode: "essential",
		async execute(_id, _params, signal, onUpdate, ctx) {
			const repo = await repoOf(ctx?.cwd ?? process.cwd());
			const file = lockFile(repo);
			const holder = holderOf(file)?.name ?? "another fixit omp";
			onUpdate?.(text(`Waiting for \`${holder}\` to finish its turn in ${repo}…`));
			const { ok, context } = await acquire(file, pi.getSessionName() ?? base, true, signal);
			if (!ok) return text("Cancelled before the lock was free.");
			return text([`You hold the lock on ${repo} until your turn ends.`, context].filter(Boolean).join(" "));
		},
	});

	pi.registerTool<{ summary: string }>({
		name: "fixit_title",
		label: "Fixit Title",
		description:
			"Name this session after what the task is about. Call it once, right after your first " +
			"analysis of the task, and again only if your understanding changes a lot.",
		parameters: pi.zod.object({
			summary: pi.zod
				.string()
				.describe("3 to 6 lowercase words: the bug or wish and where, e.g. `diffy log drops working tree`"),
		}),
		async execute(_id, { summary }, _signal, _onUpdate, ctx) {
			if (isSub(ctx)) return text("Only the main agent names the session.");
			const short = summary.trim().replace(/\s+/g, " ");
			await pi.setSessionName(`${base}: ${short}`);
			try {
				await renameTab(short);
			} catch (err) {
				return text(`Session named; zellij tab not renamed: ${err}`);
			}
			return text(`Session named \`${base}: ${short}\`.`);
		},
	});
}
