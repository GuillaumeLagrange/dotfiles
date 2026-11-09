// Publishes this session's state for omp-panel (pkgs/omp-panel).
//
// Every interactive omp running in a zellij pane keeps one JSON file at
// $XDG_RUNTIME_DIR/omp-panel/<session>/<pane>.json, rewritten on each change and
// removed on shutdown. The state machine follows herdr's omp integration: idle
// is debounced, a tool approval or an `ask` blocks, and a retryable provider
// error keeps the pane working for a grace period before it counts as blocked.
// Alongside the state: when it last changed, the tool running, the model and how
// full its context is.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

type State = "working" | "idle" | "blocked";

export type PaneFile = {
	session: string;
	pane_id: number;
	pid: number;
	state: State;
	blocked_reason: string | null;
	last_message: string | null;
	cwd: string;
	// omp keeps the session's current title at the top of this file, rewritten in
	// place on every rename; the panel reads it there.
	session_file: string | null;
	updated_at: number;
	// When `state` last changed.
	state_since: number;
	// Last working -> idle transition; the panel shows the pane as done until it
	// has been viewed since.
	finished_at: number | null;
	model: string | null;
	context_percent: number | null;
	// The tool running right now, by its intent when the model gave one.
	activity: string | null;
};

type Ctx = {
	hasUI?: boolean;
	cwd?: string;
	isIdle?: () => boolean;
	sessionManager?: { getSessionFile?: () => string | undefined };
	model?: unknown;
	models?: { current?: () => unknown };
	getContextUsage?: () => { percent?: number | null } | undefined;
};
type Handler = (event: unknown, ctx: Ctx) => void;
type Pi = { on: (event: string, handler: Handler) => void };
type Timer = NodeJS.Timeout;

const MAX_MESSAGE = 2000;
const RETRYABLE =
	/overloaded|provider.?returned.?error|rate.?limit|too many requests|429|500|502|503|504|service.?unavailable|server.?error|internal.?error|network.?error|connection.?error|connection.?refused|connection.?lost|websocket.?closed|websocket.?error|other side closed|fetch failed|upstream.?connect|reset before headers|socket hang up|ended without|http2 request did not get a response|timed? out|timeout|terminated|retry delay/i;

/** One field of an event payload, which omp hands over untyped. */
function field(value: unknown, key: string): unknown {
	return value !== null && typeof value === "object" && key in value
		? (value as Record<string, unknown>)[key]
		: undefined;
}

function str(value: unknown): string | undefined {
	return typeof value === "string" && value ? value : undefined;
}

function durationEnv(name: string, fallback: number): number {
	const parsed = Number.parseInt(process.env[name] ?? "", 10);
	return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

export function stateDir(): string {
	const runtime = process.env.XDG_RUNTIME_DIR ?? path.join(os.tmpdir(), `omp-panel-${os.userInfo().uid}`);
	return process.env.OMP_PANEL_DIR ?? path.join(runtime, "omp-panel");
}

export function messageText(message: unknown): string | undefined {
	if (field(message, "role") !== "assistant") return undefined;
	const content = field(message, "content");
	const text =
		typeof content === "string"
			? content
			: Array.isArray(content)
				? content
						.filter((part) => field(part, "type") === "text")
						.map((part) => str(field(part, "text")) ?? "")
						.join("\n")
				: "";
	const trimmed = text.trim();
	return trimmed ? trimmed.slice(0, MAX_MESSAGE) : undefined;
}

function lastAssistant(event: unknown): unknown {
	const messages = field(event, "messages");
	if (!Array.isArray(messages)) return undefined;
	for (let i = messages.length - 1; i >= 0; i--) {
		if (field(messages[i], "role") === "assistant") return messages[i];
	}
	return undefined;
}

function retryableError(event: unknown): string | undefined {
	const assistant = lastAssistant(event);
	if (field(assistant, "stopReason") !== "error") return undefined;
	const error = String(field(assistant, "errorMessage") ?? "");
	return RETRYABLE.test(error) ? error || "retryable provider error" : undefined;
}

function askQuestion(event: unknown): string {
	const questions = field(field(event, "args"), "questions");
	if (Array.isArray(questions)) {
		for (const q of questions) {
			const text = str(field(q, "question"));
			if (text) return text;
		}
	}
	return "waiting for user input";
}

function firstLine(value: unknown): string | undefined {
	return str(value)?.split("\n", 1)[0].trim() || undefined;
}

function toolActivity(event: unknown): string {
	const name = str(field(event, "toolName")) ?? "tool";
	const args = field(event, "args");
	const intent = firstLine(field(event, "intent")) ?? firstLine(field(args, "i")) ?? firstLine(field(args, "intent"));
	if (intent) return intent;
	const target =
		firstLine(field(args, "command")) ?? firstLine(field(args, "path")) ?? firstLine(field(args, "pattern"));
	return (target ? `${name} ${target}` : name).slice(0, 200);
}

export default function ompPanel(pi: Pi) {
	const session = process.env.ZELLIJ_SESSION_NAME;
	const paneId = Number.parseInt(process.env.ZELLIJ_PANE_ID ?? "", 10);
	// omp marks the shells it spawns with OMPCODE=1: an omp started from one of
	// them is not the pane's own agent and must not overwrite its file.
	if (!session || !Number.isFinite(paneId) || process.env.OMPCODE === "1") return;

	const idleDebounceMs = durationEnv("OMP_PANEL_IDLE_DEBOUNCE_MS", 250);
	const retryGraceMs = durationEnv("OMP_PANEL_RETRY_GRACE_MS", 2500);
	const dir = path.join(stateDir(), session);
	const file = path.join(dir, `${paneId}.json`);

	let active = false; // a root session with a UI has started
	let agentActive = false;
	let retryHold = false;
	let failure: string | undefined;
	let blockedCount = 0;
	let blockedMessage: string | undefined;
	let lastMessage: string | undefined;
	let cwd = process.cwd();
	let sessionFile: string | undefined;
	let published: State | undefined;
	let finishedAt: number | undefined;
	let stateSince = Date.now();
	let model: string | undefined;
	let contextPercent: number | undefined;
	// By tool call id: parallel calls each run until their own end.
	const running = new Map<string, string>();
	let idleTimer: Timer | undefined;
	let retryTimer: Timer | undefined;

	function desired(): { state: State; reason?: string } {
		if (blockedCount > 0) return { state: "blocked", reason: blockedMessage };
		if (failure && !retryHold) return { state: "blocked", reason: failure };
		if (agentActive || retryHold) return { state: "working" };
		return { state: "idle" };
	}

	function write() {
		const next = desired();
		const now = Date.now();
		if (published === "working" && next.state === "idle") finishedAt = now;
		if (published !== next.state) stateSince = now;
		published = next.state;
		const body: PaneFile = {
			session: session as string,
			pane_id: paneId,
			pid: process.pid,
			state: next.state,
			blocked_reason: next.reason ?? null,
			last_message: lastMessage ?? null,
			cwd,
			session_file: sessionFile ?? null,
			updated_at: now,
			state_since: stateSince,
			finished_at: finishedAt ?? null,
			model: model ?? null,
			context_percent: contextPercent ?? null,
			activity: next.state === "working" ? ([...running.values()].at(-1) ?? null) : null,
		};
		try {
			fs.mkdirSync(dir, { recursive: true });
			const tmp = `${file}.${process.pid}.tmp`;
			fs.writeFileSync(tmp, JSON.stringify(body));
			fs.renameSync(tmp, file);
		} catch {
			// The panel is a convenience; never let it break a session.
		}
	}

	function remove() {
		fs.rmSync(file, { force: true });
	}

	function clearTimers() {
		clearTimeout(idleTimer);
		clearTimeout(retryTimer);
		idleTimer = retryTimer = undefined;
	}

	function activate(ctx: Ctx): boolean {
		if (active) return true;
		if (ctx?.hasUI !== true) return false;
		active = true;
		process.once("exit", remove);
		return true;
	}

	function refresh(ctx: Ctx) {
		if (typeof ctx?.cwd === "string") cwd = ctx.cwd;
		try {
			sessionFile = str(ctx?.sessionManager?.getSessionFile?.()) ?? sessionFile;
		} catch {}
		try {
			const current = ctx?.models?.current?.() ?? ctx?.model;
			model = str(field(current, "id")) ?? str(field(current, "name")) ?? model;
			const percent = ctx?.getContextUsage?.()?.percent;
			if (typeof percent === "number" && Number.isFinite(percent)) contextPercent = percent;
		} catch {}
	}

	function block(reason: string) {
		clearTimers();
		blockedCount++;
		blockedMessage = reason;
		write();
	}

	function unblock() {
		blockedCount = Math.max(0, blockedCount - 1);
		if (blockedCount === 0) blockedMessage = undefined;
		write();
	}

	pi.on("session_start", (_event, ctx) => {
		if (!activate(ctx)) return;
		refresh(ctx);
		// A reload replaces the extension mid-run without another agent_start.
		agentActive = ctx?.isIdle?.() === false;
		write();
	});

	pi.on("session_switch", (_event, ctx) => {
		if (!activate(ctx)) return;
		refresh(ctx);
		clearTimers();
		agentActive = retryHold = false;
		failure = blockedMessage = lastMessage = undefined;
		blockedCount = 0;
		finishedAt = undefined;
		published = undefined;
		running.clear();
		write();
	});

	pi.on("agent_start", (_event, ctx) => {
		if (!activate(ctx)) return;
		refresh(ctx);
		clearTimers();
		retryHold = false;
		failure = undefined;
		agentActive = true;
		write();
	});

	pi.on("message_end", (event, ctx) => {
		if (!active) return;
		const text = messageText(field(event, "message"));
		if (text === undefined) return;
		refresh(ctx);
		lastMessage = text;
		write();
	});

	pi.on("tool_approval_requested", (event, ctx) => {
		if (!activate(ctx)) return;
		block(str(field(event, "reason")) ?? `${str(field(event, "toolName")) ?? "Tool"} approval`);
	});

	pi.on("tool_approval_resolved", (_event, ctx) => {
		if (!activate(ctx)) return;
		unblock();
	});

	pi.on("tool_execution_start", (event, ctx) => {
		if (!activate(ctx)) return;
		running.set(String(field(event, "toolCallId") ?? running.size), toolActivity(event));
		if (field(event, "toolName") === "ask") block(askQuestion(event));
		else write();
	});

	pi.on("tool_execution_end", (event, ctx) => {
		if (!activate(ctx)) return;
		running.delete(String(field(event, "toolCallId")));
		if (field(event, "toolName") === "ask") unblock();
		else write();
	});

	pi.on("agent_end", (event) => {
		// A duplicate end while a retry holds the pane working must not settle it.
		if (!active || !agentActive || field(event, "willContinue") === true) return;
		agentActive = false;
		running.clear();
		const text = messageText(lastAssistant(event));
		if (text !== undefined) lastMessage = text;

		clearTimers();
		const retry = retryableError(event);
		if (retry) {
			retryHold = true;
			failure = retry;
			write();
			retryTimer = setTimeout(() => {
				retryTimer = undefined;
				retryHold = false;
				write();
			}, retryGraceMs);
			retryTimer.unref?.();
			return;
		}
		failure = undefined;
		idleTimer = setTimeout(() => {
			idleTimer = undefined;
			write();
		}, idleDebounceMs);
		idleTimer.unref?.();
	});

	pi.on("session_shutdown", () => {
		if (!active) return;
		clearTimers();
		remove();
	});
}
