// Run with: cd ai/omp && npm test

import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, assert, beforeEach, describe, it } from "vitest";
import fixit from "./extensions/fixit.ts";

type Handler = (event: unknown, ctx: unknown) => unknown;
type Tool = { execute: (...args: unknown[]) => Promise<{ content: { text: string }[] }> };

let dir: string;
let lockFile: string;
let main: { hasUI: boolean; cwd: string; agent: { kind: string } };
const others: ChildProcess[] = [];

function load() {
	process.env.OMP_FIXIT = "mine";
	const handlers = new Map<string, Handler>();
	const tools = new Map<string, Tool>();
	fixit({
		on: (event: string, handler: Handler) => handlers.set(event, handler),
		zod: { object: () => ({}), string: () => ({ describe: () => ({}) }) },
		getSessionName: () => "mine: task",
		setSessionName: async () => {},
		registerTool: (tool: Tool & { name: string }) => tools.set(tool.name, tool),
	} as never);
	const emit = (event: string, payload: unknown = {}, ctx: unknown = main) => handlers.get(event)?.(payload, ctx);
	const lock = (signal?: AbortSignal) => tools.get("fixit_lock")!.execute("id", {}, signal, undefined, main);
	return { emit, lock };
}

const held = () => spawnSync("flock", ["-n", lockFile, "true"]).status !== 0;
// Waits for the lock to be released, as another omp would.
const freed = () =>
	new Promise<boolean>((resolve) => spawn("flock", ["-w", "5", lockFile, "true"]).once("exit", (code) => resolve(code === 0)));

// Another fixit omp: holds the lock until its stdin closes.
async function other(name: string): Promise<ChildProcess> {
	fs.mkdirSync(path.dirname(lockFile), { recursive: true });
	fs.writeFileSync(`${lockFile}.holder`, JSON.stringify({ pid: 1, name }));
	const child = spawn("flock", ["-n", lockFile, "-c", "echo; exec cat"], { stdio: ["pipe", "pipe", "ignore"] });
	others.push(child);
	await new Promise((resolve) => child.stdout.once("data", resolve));
	return child;
}

beforeEach(() => {
	dir = fs.mkdtempSync(path.join(os.tmpdir(), "fixit-test-"));
	process.env.OMP_FIXIT_LOCK_DIR = path.join(dir, "locks");
	delete process.env.OMPCODE;
	main = { hasUI: true, cwd: dir, agent: { kind: "main" } };
	lockFile = path.join(dir, "locks", `${dir.replaceAll("/", "%")}.lock`);
});

afterEach(async () => {
	for (const child of others.splice(0)) child.stdin?.end();
	fs.rmSync(dir, { recursive: true, force: true });
});

describe("fixit lock", () => {
	it("holds the repo lock from the first tool call until the main agent's turn ends", async () => {
		const { emit } = load();
		assert.isUndefined(await emit("tool_call", { toolName: "bash" }));
		assert.isTrue(held(), "another omp cannot take it mid-turn");

		emit("agent_end", {}, { ...main, agent: { kind: "sub" } });
		assert.isTrue(held(), "a subagent ending does not end the turn");
		assert.isUndefined(await emit("tool_call", { toolName: "read" }, { ...main, agent: { kind: "sub" } }));

		emit("agent_end");
		assert.isTrue(await freed());
	});

	it("blocks tools while another fixit omp works, and fixit_lock waits for its turn", async () => {
		const { emit, lock } = load();
		const holder = await other("theirs");

		const blocked = (await emit("tool_call", { toolName: "edit" })) as { block: boolean; reason: string };
		assert.isTrue(blocked.block);
		assert.include(blocked.reason, "`theirs`");
		assert.isUndefined(await emit("tool_call", { toolName: "fixit_lock" }), "the lock tool itself is never blocked");

		let done = false;
		const waiting = lock().then((r) => {
			done = true;
			return r;
		});
		assert.isTrue(held());
		assert.isFalse(done, "still waiting while the other omp holds the lock");

		holder.stdin?.end();
		assert.include((await waiting).content[0].text, "You hold the lock");
		assert.isUndefined(await emit("tool_call", { toolName: "edit" }));
		emit("agent_end");
	});

	it("tells the agent when another omp worked in the repo since its last turn", async () => {
		const { emit } = load();
		await emit("tool_call", { toolName: "bash" });
		emit("agent_end");
		assert.isTrue(await freed());
		(await other("theirs")).stdin?.end();
		assert.isTrue(await freed());

		const next = (await emit("tool_call", { toolName: "bash" })) as { additionalContext: string };
		assert.include(next.additionalContext, "`theirs`");
		emit("agent_end");
	});

	it("gives up waiting when the tool call is aborted", async () => {
		const { lock } = load();
		await other("theirs");
		const abort = new AbortController();
		const waiting = lock(abort.signal);
		abort.abort();
		assert.include((await waiting).content[0].text, "Cancelled");
	});
});
