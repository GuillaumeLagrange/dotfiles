// Typing `/omp` opens a picker over the other omp sessions:
// the live ones omp-panel publishes first, then the most recently written
// session files. Picking one replaces the token with a markdown link to its
// session file, which the receiving omp reads.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { type PaneFile, stateDir } from "./omp-panel.ts";

type Item = { value: string; label: string; description?: string };
type Suggestions = { items: Item[]; prefix: string };
type Completion = { lines: string[]; cursorLine: number; cursorCol: number };
type Provider = {
	getSuggestions: (lines: string[], line: number, col: number, ...rest: unknown[]) => Promise<Suggestions | null>;
	applyCompletion: (lines: string[], line: number, col: number, item: Item, prefix: string) => Completion;
	[key: string]: unknown;
};
type Ctx = {
	hasUI?: boolean;
	sessionManager?: { getSessionFile?: () => string | undefined };
	ui?: { addAutocompleteProvider?: (factory: (base: Provider) => Provider) => void };
};
type Pi = { on: (event: string, handler: (event: unknown, ctx: Ctx) => void) => void };

export type Session = {
	file: string;
	title: string;
	cwd?: string;
	// Live sessions only.
	state?: PaneFile["state"];
	zellij?: string;
	at: number;
};

const RECENT = 30;
const HEADER_BYTES = 8192;
const CACHE_MS = 2000;
// Unlike `/session`, no omp command starts with it: the token counts anywhere, even first.
const WORD = "omp";

/** The `/omp<filter>` token ending `before`: `/omp`, `/omp:wt` or `/omp-wt` filter on "wt". */
export function parseToken(before: string): { prefix: string; filter: string } | null {
	const m = /(^|\s)(\/([^\s/]*))$/.exec(before);
	if (!m || !m[3].startsWith(WORD)) return null;
	return { prefix: m[2], filter: m[3].slice(WORD.length).replace(/^[:\-]/, "") };
}

function header(file: string): { title?: string; cwd?: string } {
	let fd: number | undefined;
	try {
		fd = fs.openSync(file, "r");
		const buf = Buffer.alloc(HEADER_BYTES);
		const text = buf.toString("utf8", 0, fs.readSync(fd, buf, 0, HEADER_BYTES, 0));
		const out: { title?: string; cwd?: string } = {};
		for (const line of text.split("\n").slice(0, 4)) {
			try {
				const entry = JSON.parse(line);
				if (entry.type === "title" && typeof entry.title === "string") out.title = entry.title;
				if (entry.type === "session" && typeof entry.cwd === "string") out.cwd = entry.cwd;
			} catch {}
		}
		return out;
	} catch {
		return {};
	} finally {
		if (fd !== undefined) fs.closeSync(fd);
	}
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (err) {
		return (err as NodeJS.ErrnoException).code === "EPERM";
	}
}

function entries(dir: string): fs.Dirent[] {
	try {
		return fs.readdirSync(dir, { withFileTypes: true });
	} catch {
		return [];
	}
}

/** Live omps first (newest update first), then the newest other session files. */
export function listSessions(opts: { panelDir: string; sessionsDir: string; self?: string }): Session[] {
	const seen = new Set<string>(opts.self ? [opts.self] : []);
	const live: Session[] = [];
	for (const zellij of entries(opts.panelDir)) {
		if (!zellij.isDirectory()) continue;
		for (const pane of entries(path.join(opts.panelDir, zellij.name))) {
			if (!pane.name.endsWith(".json")) continue;
			let body: PaneFile;
			try {
				body = JSON.parse(fs.readFileSync(path.join(opts.panelDir, zellij.name, pane.name), "utf8"));
			} catch {
				continue;
			}
			if (!body.session_file || seen.has(body.session_file) || !alive(body.pid)) continue;
			seen.add(body.session_file);
			const { title, cwd } = header(body.session_file);
			live.push({
				file: body.session_file,
				title: title ?? path.basename(body.session_file),
				cwd: cwd ?? body.cwd,
				state: body.state,
				zellij: body.session,
				at: body.updated_at,
			});
		}
	}
	live.sort((a, b) => b.at - a.at);

	const files: { file: string; at: number }[] = [];
	for (const project of entries(opts.sessionsDir)) {
		if (!project.isDirectory()) continue;
		const dir = path.join(opts.sessionsDir, project.name);
		for (const f of entries(dir)) {
			if (!f.isFile() || !f.name.endsWith(".jsonl")) continue;
			const file = path.join(dir, f.name);
			if (seen.has(file)) continue;
			try {
				files.push({ file, at: fs.statSync(file).mtimeMs });
			} catch {}
		}
	}
	files.sort((a, b) => b.at - a.at);
	const recent = files.slice(0, RECENT).map(({ file, at }) => {
		const { title, cwd } = header(file);
		return { file, title: title ?? path.basename(file), cwd, at };
	});
	return [...live, ...recent];
}

function age(ms: number): string {
	const s = Math.max(0, Math.round(ms / 1000));
	if (s < 60) return `${s}s`;
	if (s < 3600) return `${Math.floor(s / 60)}m`;
	if (s < 86400) return `${Math.floor(s / 3600)}h`;
	return `${Math.floor(s / 86400)}d`;
}

export function toItem(s: Session, now: number): Item {
	const title = s.title.replace(/[[\]]/g, "");
	const parts = [s.state, s.zellij, age(now - s.at), s.cwd && path.basename(s.cwd)].filter(Boolean);
	return { value: `[${title}](${s.file}) `, label: title, description: parts.join(" · ") };
}

function matches(item: Item, filter: string): boolean {
	const hay = `${item.label} ${item.description ?? ""}`.toLowerCase();
	return filter
		.toLowerCase()
		.split(/[-_.]+/)
		.every((w) => hay.includes(w));
}

export default function sessionRef(pi: Pi): void {
	let installed = false;
	let self: string | undefined;
	let cache: { at: number; sessions: Session[] } | undefined;

	function sessions(sessionsDir: string): Session[] {
		const now = Date.now();
		if (!cache || now - cache.at > CACHE_MS) {
			cache = { at: now, sessions: listSessions({ panelDir: stateDir(), sessionsDir, self }) };
		}
		return cache.sessions;
	}

	pi.on("session_start", (_event, ctx) => {
		try {
			self = ctx.sessionManager?.getSessionFile?.() ?? self;
		} catch {}
		if (installed || ctx.hasUI !== true || !ctx.ui?.addAutocompleteProvider) return;
		installed = true;
		ctx.ui.addAutocompleteProvider((base) => {
			const getSuggestions: Provider["getSuggestions"] = async (lines, line, col, ...rest) => {
				const token = parseToken((lines[line] ?? "").slice(0, col));
				if (!token) return base.getSuggestions(lines, line, col, ...rest);
				const sessionsDir = self
					? path.dirname(path.dirname(self))
					: path.join(os.homedir(), ".omp", "agent", "sessions");
				const now = Date.now();
				const items = sessions(sessionsDir)
					.map((s) => toItem(s, now))
					.filter((item) => matches(item, token.filter));
				return items.length > 0 ? { items, prefix: token.prefix } : null;
			};
			const applyCompletion: Provider["applyCompletion"] = (lines, line, col, item, prefix) => {
				if (!parseToken(prefix) || !item.value.startsWith("[")) {
					return base.applyCompletion(lines, line, col, item, prefix);
				}
				const text = lines[line] ?? "";
				const head = text.slice(0, col - prefix.length) + item.value;
				const next = [...lines];
				next[line] = head + text.slice(col);
				return { lines: next, cursorLine: line, cursorCol: head.length };
			};
			// The base provider is a class with private fields: call its methods on itself.
			return new Proxy(base, {
				get(target, key) {
					if (key === "getSuggestions") return getSuggestions;
					if (key === "applyCompletion") return applyCompletion;
					const value = Reflect.get(target, key, target);
					return typeof value === "function" ? value.bind(target) : value;
				},
			});
		});
	});

	pi.on("session_switch", (_event, ctx) => {
		try {
			self = ctx.sessionManager?.getSessionFile?.() ?? self;
			cache = undefined;
		} catch {}
	});
}
