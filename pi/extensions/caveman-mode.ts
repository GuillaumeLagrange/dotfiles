import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Always-on caveman mode for pi — the equivalent of the Claude Code
// SessionStart hook in claude/settings.json. Reads the shared caveman skill
// (single source of truth in claude/skills, symlinked to ~/.claude/skills) and
// appends its body to the system prompt each turn, so the mode is active
// without having to invoke /skill:caveman.
export default function (pi: ExtensionAPI) {
  const skillPath = join(homedir(), ".claude", "skills", "caveman", "SKILL.md");

  const loadBody = (): string | undefined => {
    try {
      const raw = readFileSync(skillPath, "utf8");
      // Strip a leading YAML frontmatter block (--- ... ---), keep the body.
      return raw.replace(/^---\n[\s\S]*?\n---\n/, "").trim() || undefined;
    } catch {
      return undefined; // skill missing → no-op
    }
  };

  pi.on("before_agent_start", async (event) => {
    const body = loadBody();
    if (!body) return;
    if (event.systemPrompt.includes(body)) return; // avoid double-append
    return { systemPrompt: `${event.systemPrompt}\n\n${body}` };
  });
}
