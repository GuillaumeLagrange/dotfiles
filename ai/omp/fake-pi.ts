// A stand-in for the extension API in tests: records handlers and tools.

// Any chain of zod calls (`z.string().optional().describe(…)`) is accepted and ignored.
const zod: unknown = new Proxy(() => zod, { get: () => zod, apply: () => zod });

export type Tool = {
	name: string;
	execute: (id: string, params: never, signal: AbortSignal | undefined, onUpdate: unknown, ctx: unknown) => Promise<{
		content: { type: string; text: string }[];
	}>;
};

export function fakePi() {
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	const tools = new Map<string, Tool>();
	const prompts: string[] = [];
	const pi = {
		zod,
		on(event: string, handler: (event: unknown, ctx: unknown) => unknown) {
			handlers.set(event, handler);
		},
		registerTool(tool: Tool) {
			tools.set(tool.name, tool);
		},
		async sendUserMessage(text: string) {
			prompts.push(text);
		},
	};
	return { pi, handlers, tools, prompts };
}
