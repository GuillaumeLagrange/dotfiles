// Run with: cd ai/omp && npm test

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, assert, beforeEach, describe, it, vi } from "vitest";
import ompPanel, { type PaneFile } from "./extensions/omp-panel.ts";

type Handler = (event: unknown, ctx: unknown) => void;

let dir: string;
const ctx = { hasUI: true, cwd: "/tmp/project", sessionManager: { getSessionFile: () => "/tmp/project/sess-1.jsonl" } };

function load(env: Record<string, string> = {}) {
	Object.assign(process.env, { ZELLIJ_SESSION_NAME: "work", ZELLIJ_PANE_ID: "3", ...env });
	const handlers = new Map<string, Handler>();
	ompPanel({ on: (event, handler) => handlers.set(event, handler as Handler) });
	return (event: string, payload: unknown = {}, context: unknown = ctx) => handlers.get(event)?.(payload, context);
}

function read(): PaneFile | undefined {
	const file = path.join(dir, "work", "3.json");
	return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : undefined;
}

const assistant = (text: string, extra: Record<string, unknown> = {}) => ({
	role: "assistant",
	content: [
		{ type: "thinking", thinking: "hidden" },
		{ type: "text", text },
	],
	...extra,
});

beforeEach(() => {
	vi.useFakeTimers();
	dir = fs.mkdtempSync(path.join(os.tmpdir(), "omp-panel-test-"));
	process.env.OMP_PANEL_DIR = dir;
	delete process.env.OMPCODE;
});

afterEach(() => {
	vi.useRealTimers();
	fs.rmSync(dir, { recursive: true, force: true });
});

describe("omp-panel extension", () => {
	it("goes working, then idle only once the debounce settles, and records the reply", () => {
		const emit = load();
		emit("session_start");
		assert.equal(read()?.state, "idle");
		assert.equal(read()?.finished_at, null, "a fresh session has nothing to review");

		emit("agent_start");
		assert.equal(read()?.state, "working");
		emit("message_end", { message: { role: "user", content: "hi" } });
		emit("message_end", { message: assistant("partial answer") });
		assert.equal(read()?.last_message, "partial answer");

		emit("agent_end", { messages: [assistant("final answer")] });
		assert.equal(read()?.state, "working", "idle is debounced");
		vi.advanceTimersByTime(250);
		const file = read();
		assert.equal(file?.state, "idle");
		assert.equal(file?.last_message, "final answer");
		assert.isNumber(file?.finished_at);
		assert.equal(file?.cwd, "/tmp/project");
		assert.equal(file?.session_file, "/tmp/project/sess-1.jsonl");
	});

	it("a new turn inside the debounce cancels the pending idle", () => {
		const emit = load();
		emit("agent_start");
		emit("agent_end", { messages: [] });
		emit("agent_start");
		vi.advanceTimersByTime(1000);
		assert.equal(read()?.state, "working");
		assert.equal(read()?.finished_at, null);
	});

	it("blocks on a tool approval and on ask, with the reason, until resolved", () => {
		const emit = load();
		emit("agent_start");
		emit("tool_approval_requested", { toolName: "bash", reason: "rm -rf build" });
		assert.equal(read()?.state, "blocked");
		assert.equal(read()?.blocked_reason, "rm -rf build");
		emit("tool_approval_resolved");
		assert.equal(read()?.state, "working");
		assert.equal(read()?.blocked_reason, null);

		emit("tool_execution_start", { toolName: "ask", args: { questions: [{ question: "Ship it?" }] } });
		assert.equal(read()?.state, "blocked");
		assert.equal(read()?.blocked_reason, "Ship it?");
		emit("tool_execution_start", { toolName: "bash", args: {} });
		emit("tool_execution_end", { toolName: "ask" });
		assert.equal(read()?.state, "working");
	});

	it("holds a retryable provider error as working, then blocks once the grace runs out", () => {
		const emit = load();
		emit("agent_start");
		emit("agent_end", { messages: [assistant("", { stopReason: "error", errorMessage: "429 rate limit" })] });
		assert.equal(read()?.state, "working");
		vi.advanceTimersByTime(2500);
		assert.equal(read()?.state, "blocked");
		assert.equal(read()?.blocked_reason, "429 rate limit");

		emit("agent_start");
		assert.equal(read()?.state, "working", "the retry starting clears the failure");
	});

	it("a non-retryable error settles to idle", () => {
		const emit = load();
		emit("agent_start");
		emit("agent_end", { messages: [assistant("", { stopReason: "error", errorMessage: "invalid api key" })] });
		vi.advanceTimersByTime(250);
		assert.equal(read()?.state, "idle");
	});

	it("an end that will continue, or a duplicate end, does not settle", () => {
		const emit = load();
		emit("agent_start");
		emit("agent_end", { willContinue: true, messages: [] });
		vi.advanceTimersByTime(1000);
		assert.equal(read()?.state, "working");

		emit("agent_end", { messages: [assistant("", { stopReason: "error", errorMessage: "overloaded" })] });
		emit("agent_end", { messages: [] });
		assert.equal(read()?.state, "working", "the duplicate must not cancel the retry hold");
	});

	it("removes its file on shutdown", () => {
		const emit = load();
		emit("session_start");
		assert.isDefined(read());
		emit("session_shutdown");
		assert.isUndefined(read());
	});

	it("stays silent without a UI, outside zellij, and in a nested omp", () => {
		load()("session_start", {}, { hasUI: false });
		assert.isUndefined(read());

		load({ OMPCODE: "1" })("session_start");
		assert.isUndefined(read());

		delete process.env.OMPCODE;
		load({ ZELLIJ_PANE_ID: "" })("session_start");
		assert.isUndefined(read());
	});
});
