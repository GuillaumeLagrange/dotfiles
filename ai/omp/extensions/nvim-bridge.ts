// Lets an editor push text into this session's composer over a unix socket.
//
// Every interactive session listens on ~/.omp/run/nvim-bridge/<pid>.sock and
// writes a <pid>.json descriptor next to it, carrying the cwd so a client can
// pick the session for its project. Protocol is newline-delimited JSON:
//
//   {"op":"send","text":"..."} -> paste into the composer, no submit
//   {"op":"submit"}            -> submit whatever the composer holds

import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

// Overridable so tests stay out of the real session registry.
const RUN_DIR = process.env.OMP_NVIM_BRIDGE_DIR ?? path.join(os.homedir(), ".omp", "run", "nvim-bridge");

type Ui = {
	pasteToEditor: (text: string) => unknown;
	getEditorText: () => unknown;
	setEditorText: (text: string) => unknown;
};
type Ctx = {
	hasUI: boolean;
	cwd: string;
	ui: Ui;
	sessionManager?: { getSessionId?: () => string | undefined };
};
type Pi = {
	on: (event: string, handler: (event: unknown, ctx: Ctx) => void) => void;
	sendUserMessage: (text: string) => unknown;
	logger?: { error?: (message: string) => void };
};

// Env comes from the shell that launched omp; absent outside zellij.
function focusPane(): void {
	const session = process.env.ZELLIJ_SESSION_NAME;
	const pane = process.env.ZELLIJ_PANE_ID;
	if (!session || !pane) return;
	const proc = spawn("zellij", ["-s", session, "action", "focus-pane-id", pane], {
		stdio: "ignore",
		detached: true,
	});
	proc.on("error", () => {});
	proc.unref();
}

export default function nvimBridge(pi: Pi) {
	let server: net.Server | undefined;
	const sockPath = path.join(RUN_DIR, `${process.pid}.sock`);
	const metaPath = path.join(RUN_DIR, `${process.pid}.json`);

	async function dispatch(ctx: Ctx, line: string): Promise<string> {
		const msg: unknown = JSON.parse(line);
		const op = msg && typeof msg === "object" && "op" in msg ? msg.op : undefined;
		const text = msg && typeof msg === "object" && "text" in msg ? String(msg.text) : "";
		if (op === "send") {
			// Don't glue the payload onto whatever the user was typing: break the
			// line first, unless the composer already sits on a fresh one.
			const composer = String((await ctx.ui.getEditorText()) ?? "");
			const currentLine = composer.slice(composer.lastIndexOf("\n") + 1);
			await ctx.ui.pasteToEditor(currentLine === "" ? text : `\n${text}`);
			focusPane();
		} else if (op === "submit") {
			const pending = String((await ctx.ui.getEditorText()) ?? "").trim();
			if (pending) {
				await ctx.ui.setEditorText("");
				await pi.sendUserMessage(pending);
			}
		} else {
			return JSON.stringify({ ok: false, error: `unknown op: ${String(op)}` });
		}
		return JSON.stringify({ ok: true });
	}

	pi.on("session_start", (_event, ctx) => {
		// Only a session with a live composer has anywhere to put the text.
		if (!ctx.hasUI || server) return;
		fs.mkdirSync(RUN_DIR, { recursive: true });
		fs.rmSync(sockPath, { force: true });

		// One queue for the whole server: nvim opens a connection per op, and a
		// `send` must finish pasting before the `submit` behind it reads the
		// composer.
		let queue = Promise.resolve();
		server = net.createServer((sock) => {
			sock.on("error", () => {});
			let buf = "";
			sock.on("data", (chunk: Buffer) => {
				buf += chunk.toString("utf8");
				const lines = buf.split("\n");
				buf = lines.pop() ?? "";
				for (const line of lines) {
					if (!line.trim()) continue;
					// A throw escaping here is a fatal uncaughtException: socket
					// callbacks run outside extension dispatch.
					queue = queue
						.then(() => dispatch(ctx, line))
						.catch((err: unknown) => JSON.stringify({ ok: false, error: String(err) }))
						.then((reply) => {
							sock.write(`${reply}\n`);
						})
						.catch(() => {});
				}
			});
		});
		server.on("error", (err) => pi.logger?.error?.(`nvim-bridge: ${err.message}`));
		server.listen(sockPath, () =>
			fs.writeFileSync(
				metaPath,
				JSON.stringify({
					pid: process.pid,
					cwd: ctx.cwd,
					socket: sockPath,
					// Lets a client resume this conversation in another terminal.
					// `omp --resume` only accepts an id whose file already exists,
					// and the file appears on the first turn.
					session: ctx.sessionManager?.getSessionId?.() ?? null,
					file: ctx.sessionManager?.getSessionFile?.() ?? null,
				}),
			),
		);
		server.unref();
	});

	pi.on("session_shutdown", () => {
		server?.close();
		server = undefined;
		fs.rmSync(sockPath, { force: true });
		fs.rmSync(metaPath, { force: true });
	});
}
