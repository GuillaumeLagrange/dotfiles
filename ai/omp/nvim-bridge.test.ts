// Run with: cd ai/omp && npm test
//
// Lives outside extensions/ on purpose: omp auto-loads every .ts in that
// directory as an extension.

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { afterAll, assert, beforeAll, describe, it } from "vitest";

const RUN_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "nvim-bridge-test-"));
process.env.OMP_NVIM_BRIDGE_DIR = RUN_DIR;
// Keep the test from grabbing focus in whatever zellij session runs it.
delete process.env.ZELLIJ_SESSION_NAME;
delete process.env.ZELLIJ_PANE_ID;

// Dynamic: the extension reads OMP_NVIM_BRIDGE_DIR at import time, so the env
// above has to be set first.
const { default: nvimBridge } = await import("./extensions/nvim-bridge.ts");

const pastes: string[] = [];
const prompts: string[] = [];
let editorText = "";
let pasteDelayMs = 0;

const handlers = new Map<string, (event: unknown, ctx: unknown) => void>();
const pi = {
	on(event: string, handler: (event: unknown, ctx: unknown) => void) {
		handlers.set(event, handler);
	},
	async sendUserMessage(text: string) {
		prompts.push(text);
	},
};
const ctx = {
	hasUI: true,
	cwd: "/tmp/project",
	sessionManager: {
		getSessionId: () => "sess-abc123",
		getSessionFile: () => "/tmp/project/sess-abc123.jsonl",
	},
	ui: {
		async pasteToEditor(text: string) {
			await new Promise((resolve) => setTimeout(resolve, pasteDelayMs));
			pastes.push(text);
			editorText += text;
		},
		getEditorText: () => editorText,
		setEditorText(text: string) {
			editorText = text;
		},
	},
};

const sockPath = path.join(RUN_DIR, `${process.pid}.sock`);
const metaPath = path.join(RUN_DIR, `${process.pid}.json`);

/** One op per connection, like the nvim backend does. */
async function request(msg: unknown): Promise<string> {
	return await new Promise((resolve, reject) => {
		const sock = net.connect(sockPath, () => sock.write(`${JSON.stringify(msg)}\n`));
		sock.on("data", (data) => {
			resolve(data.toString().trim());
			sock.end();
		});
		sock.on("error", reject);
	});
}

describe("nvim-bridge", () => {
	beforeAll(async () => {
		nvimBridge(pi);
		handlers.get("session_start")?.({}, ctx);
		for (let i = 0; i < 100 && !fs.existsSync(metaPath); i++) {
			await new Promise((resolve) => setTimeout(resolve, 10));
		}
	});

	afterAll(() => {
		handlers.get("session_shutdown")?.({}, ctx);
		fs.rmSync(RUN_DIR, { recursive: true, force: true });
	});

	it("advertises the session with its cwd, resume id and file", () => {
		assert.deepEqual(JSON.parse(fs.readFileSync(metaPath, "utf8")), {
			pid: process.pid,
			cwd: "/tmp/project",
			socket: sockPath,
			session: "sess-abc123",
			file: "/tmp/project/sess-abc123.jsonl",
		});
	});

	it("pastes sent text into the composer", async () => {
		assert.equal(await request({ op: "send", text: "@src/foo.ts:12" }), '{"ok":true}');
		assert.deepEqual(pastes, ["@src/foo.ts:12"]);
		assert.equal(editorText, "@src/foo.ts:12");
	});

	it("breaks the line when the composer is mid-sentence", async () => {
		editorText = "in this file";
		await request({ op: "send", text: "@src/foo.ts:12" });
		assert.equal(editorText, "in this file\n@src/foo.ts:12");
	});

	it("does not break the line when the composer sits on an empty one", async () => {
		editorText = "in this file\n";
		await request({ op: "send", text: "@src/foo.ts:12" });
		assert.equal(editorText, "in this file\n@src/foo.ts:12");
		editorText = "@src/foo.ts:12";
	});

	it("submits the composer and clears it", async () => {
		assert.equal(await request({ op: "submit" }), '{"ok":true}');
		assert.deepEqual(prompts, ["@src/foo.ts:12"]);
		assert.equal(editorText, "");
	});

	it("ignores a submit with an empty composer", async () => {
		assert.equal(await request({ op: "submit" }), '{"ok":true}');
		assert.deepEqual(prompts, ["@src/foo.ts:12"]);
	});

	it("serializes a slow send ahead of the submit behind it", async () => {
		pasteDelayMs = 50;
		const sent = request({ op: "send", text: "context" });
		// Separate connection, issued while the paste is still in flight.
		const submitted = request({ op: "submit" });
		await Promise.all([sent, submitted]);
		pasteDelayMs = 0;
		assert.deepEqual(prompts, ["@src/foo.ts:12", "context"]);
		assert.equal(editorText, "");
	});

	it("rejects an unknown op", async () => {
		assert.equal(await request({ op: "nope" }), '{"ok":false,"error":"unknown op: nope"}');
	});

	it("deregisters on session shutdown", () => {
		handlers.get("session_shutdown")?.({}, ctx);
		assert.equal(fs.existsSync(sockPath), false);
		assert.equal(fs.existsSync(metaPath), false);
	});
});
