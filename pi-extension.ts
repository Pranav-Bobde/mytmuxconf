/** Live Pi metadata for the tmux Cmd+K picker. Load as a personal Pi extension. */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export default function (pi: ExtensionAPI) {
  const directory = join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "tmux-agent-switcher", "pi");
  const record = join(directory, `${process.pid}.json`);
  const temporary = `${record}.tmp`;
  let published = false;
  let processStartedAt: string | undefined;

  function publish(ctx: ExtensionContext, status = ctx.isIdle() ? "idle" : "busy") {
    // Headless subagents inherit TMUX_PANE, so mode, not environment alone, is the guard.
    if (ctx.mode !== "tui" || !process.env.TMUX || !process.env.TMUX_PANE) return;
    processStartedAt ??= execFileSync("ps", ["-o", "lstart=", "-p", String(process.pid)], {
      encoding: "utf8", env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
    }).trim().replace(/\s+/g, " ");
    if (!processStartedAt) return;

    let name = ctx.sessionManager.getSessionName();
    if (!name) {
      for (const entry of ctx.sessionManager.getBranch()) {
        if (entry.type !== "message" || entry.message.role !== "user") continue;
        const content = entry.message.content;
        name = typeof content === "string" ? content : content
          .filter(block => block.type === "text")
          .map(block => block.text).join(" ");
        if (name.trim()) break;
      }
    }
    name = (name || "").replace(/[\x00-\x1f\x7f-\x9f]/g, " ").replace(/\s+/g, " ").trim().slice(0, 160) || "(new session)";

    mkdirSync(directory, { recursive: true, mode: 0o700 });
    writeFileSync(temporary, JSON.stringify({
      pid: process.pid,
      processStartedAt,
      mode: "tui",
      sessionId: ctx.sessionManager.getSessionId(),
      sessionFile: ctx.sessionManager.getSessionFile() ?? null,
      leafId: ctx.sessionManager.getLeafId(),
      name,
      cwd: ctx.cwd,
      status,
      updatedAt: Date.now(),
    }), { mode: 0o600 });
    renameSync(temporary, record);
    published = true;
  }

  pi.on("session_start", (_event, ctx) => publish(ctx));
  pi.on("session_info_changed", (_event, ctx) => publish(ctx));
  // message_end runs before persistence; the next start sees the saved leaf.
  pi.on("message_start", (_event, ctx) => publish(ctx));
  pi.on("session_tree", (_event, ctx) => publish(ctx));
  pi.on("agent_start", (_event, ctx) => publish(ctx, "busy"));
  pi.on("agent_settled", (_event, ctx) => publish(ctx, "idle"));
  pi.on("session_shutdown", () => {
    if (!published) return;
    rmSync(record, { force: true });
    rmSync(temporary, { force: true });
    published = false;
  });
}
