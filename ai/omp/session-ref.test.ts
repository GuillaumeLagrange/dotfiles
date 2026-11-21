// Run with: cd ai/omp && npm test

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, assert, beforeEach, describe, it } from "vitest";
import { listSessions, parseToken } from "./extensions/session-ref.ts";

describe("parseToken", () => {
	it("matches /omp anywhere, with a filter", () => {
		assert.deepEqual(parseToken("/omp"), { prefix: "/omp", filter: "" });
		assert.deepEqual(parseToken("look at /omp"), { prefix: "/omp", filter: "" });
		assert.deepEqual(parseToken("look at /omp:wt"), { prefix: "/omp:wt", filter: "wt" });
		assert.deepEqual(parseToken("  /omp-wt"), { prefix: "/omp-wt", filter: "wt" });
	});

	it("leaves omp's commands and paths alone", () => {
		assert.isNull(parseToken("/session"));
		assert.isNull(parseToken("look at /om"));
		assert.isNull(parseToken("cat /opt/x"));
		assert.isNull(parseToken("cd ~/.omp"));
		assert.isNull(parseToken("look at a/omp"));
	});
});

describe("listSessions", () => {
	let dir: string;
	let panelDir: string;
	let sessionsDir: string;

	function session(name: string, title: string, mtime: number): string {
		const file = path.join(sessionsDir, "-proj", `${name}.jsonl`);
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(
			file,
			`${JSON.stringify({ type: "title", title })}\n${JSON.stringify({ type: "session", cwd: "/w/proj" })}\n`,
		);
		fs.utimesSync(file, mtime, mtime);
		return file;
	}

	function pane(zellij: string, id: number, pid: number, file: string, updated: number) {
		const d = path.join(panelDir, zellij);
		fs.mkdirSync(d, { recursive: true });
		fs.writeFileSync(
			path.join(d, `${id}.json`),
			JSON.stringify({
				session: zellij,
				pane_id: id,
				pid,
				state: "working",
				session_file: file,
				cwd: "/w",
				updated_at: updated,
			}),
		);
	}

	beforeEach(() => {
		dir = fs.mkdtempSync(path.join(os.tmpdir(), "session-ref-test-"));
		panelDir = path.join(dir, "panel");
		sessionsDir = path.join(dir, "sessions");
	});
	afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

	it("puts live omps first, drops dead ones and itself, lists each file once", () => {
		const self = session("self", "Me", 500);
		const live = session("live", "Live one", 100);
		const dead = session("dead", "Dead one", 300);
		session("old", "Old one", 200);
		pane("work", 1, process.pid, live, 1);
		pane("work", 2, 2 ** 22 + 12345, dead, 2);

		const got = listSessions({ panelDir, sessionsDir, self });
		assert.deepEqual(
			got.map((s) => [s.title, s.state ?? null]),
			[
				["Live one", "working"],
				["Dead one", null],
				["Old one", null],
			],
		);
		assert.equal(got[0].zellij, "work");
		assert.equal(got[1].cwd, "/w/proj");
	});
});
