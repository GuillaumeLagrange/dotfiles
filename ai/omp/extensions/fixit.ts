// Names an omp started by the `omp-fixit` CLI (modules/headless/omp-fixit.sh) after what it works
// on. OMP_FIXIT holds the task's name: the session is titled with it from the start, and the
// `fixit_title` tool appends a short summary once the agent knows what the task is about, to the
// session title (what omp-panel shows) and to the zellij tab.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

type Ctx = { hasUI?: boolean; agent?: { kind?: string } };
type ToolResult = { content: { type: "text"; text: string }[] };
type Z = {
	object: (shape: Record<string, unknown>) => unknown;
	string: () => { describe: (text: string) => unknown };
};
type Pi = {
	on: (event: string, handler: (event: unknown, ctx: Ctx) => unknown) => void;
	zod: Z;
	getSessionName: () => string | undefined;
	setSessionName: (name: string) => Promise<void>;
	registerTool: (tool: {
		name: string;
		label: string;
		description: string;
		parameters: unknown;
		execute: (id: string, params: { summary: string }, signal: unknown, onUpdate: unknown, ctx: Ctx) => Promise<ToolResult>;
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

export default function fixit(pi: Pi) {
	const base = process.env.OMP_FIXIT;
	// OMPCODE: an omp run from one of this omp's shells inherits the variable.
	if (!base || process.env.OMPCODE === "1") return;

	pi.on("session_start", async (_event, ctx) => {
		if (ctx?.hasUI === true && ctx.agent?.kind !== "sub" && !pi.getSessionName()) await pi.setSessionName(base);
	});

	pi.registerTool({
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
			if (ctx?.agent?.kind === "sub") return text("Only the main agent names the session.");
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
