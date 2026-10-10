import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const source = join(import.meta.dir, "../pi-extension.ts");
const factory = existsSync(source) ? (await import(source)).default : undefined;
let root: string;
let saved: Record<string, string | undefined>;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "pi-switcher-test-"));
  saved = Object.fromEntries(["XDG_CACHE_HOME", "TMUX", "TMUX_PANE", "TZ"].map(key => [key, process.env[key]]));
  process.env.XDG_CACHE_HOME = root;
  process.env.TMUX = "/tmp/test-tmux/default,1,0";
  process.env.TMUX_PANE = "%7";
});

afterEach(() => {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  rmSync(root, { recursive: true, force: true });
});

function harness(mode = "tui") {
  const handlers = new Map<string, Function[]>();
  let idle = true;
  let name: string | undefined = "Fix auth";
  let sessionId = "session-a";
  let sessionFile: string | undefined = "/custom sessions/session-a.jsonl";
  let leafId: string | null = "user-a";
  let branch: any[] = [{ type: "message", id: "user-a", parentId: null,
    message: { role: "user", content: [{ type: "text", text: "First request" }] } }];
  const ctx = {
    mode, hasUI: mode === "tui" || mode === "rpc", cwd: "/workspace/project", isIdle: () => idle,
    sessionManager: {
      getSessionName: () => name, getSessionId: () => sessionId,
      getSessionFile: () => sessionFile, getLeafId: () => leafId, getBranch: () => branch,
    },
  };
  factory?.({ on(event: string, handler: Function) {
    handlers.set(event, [...(handlers.get(event) ?? []), handler]);
  } });
  const record = join(root, "tmux-agent-switcher/pi", `${process.pid}.json`);
  return {
    ctx, record,
    async emit(type: string, extra = {}) {
      for (const handler of handlers.get(type) ?? []) await handler({ type, ...extra }, ctx);
    },
    read() {
      expect(existsSync(record)).toBe(true);
      return JSON.parse(readFileSync(record, "utf8"));
    },
    idle(value: boolean) { idle = value; },
    name(value: string | undefined) { name = value; },
    session(id: string, file: string | undefined) { sessionId = id; sessionFile = file; },
    branch(value: any[], leaf: string | null) { branch = value; leafId = leaf; },
  };
}

describe("Pi live-session bridge", () => {
  test("publishes exact persistent session metadata at session start", async () => {
    const app = harness();
    expect(existsSync(app.record)).toBe(false);
    await app.emit("session_start", { reason: "startup" });
    expect(app.read()).toMatchObject({
      pid: process.pid, mode: "tui", sessionId: "session-a", sessionFile: "/custom sessions/session-a.jsonl",
      leafId: "user-a", name: "Fix auth", cwd: "/workspace/project", status: "idle",
    });
    expect(app.read().updatedAt).toBeGreaterThan(0);
    expect(statSync(app.record).mode & 0o777).toBe(0o600);
  });

  test("records the process incarnation for rejecting stale reused PIDs", async () => {
    const app = harness();
    await app.emit("session_start", { reason: "startup" });
    expect(app.read().processStartedAt).toBeString();
    expect(app.read().processStartedAt.trim().length).toBeGreaterThan(0);
  });

  test("normalizes the process start time to UTC despite Pi's timezone", async () => {
    process.env.TZ = "Pacific/Honolulu";
    const expected = execFileSync("ps", ["-o", "lstart=", "-p", String(process.pid)], {
      encoding: "utf8", env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
    }).trim().replace(/\s+/g, " ");
    const app = harness();
    await app.emit("session_start", { reason: "startup" });
    expect(app.read().processStartedAt).toBe(expected);
  });

  test("publishes the persisted user at the next message start while busy", async () => {
    const app = harness();
    app.name(undefined);
    app.branch([], null);
    await app.emit("session_start", { reason: "new" });
    app.idle(false);
    await app.emit("agent_start");
    const entry = { type: "message", id: "new-user", parentId: null,
      message: { role: "user", content: "Latest request" } };
    await app.emit("message_start", { message: entry.message });
    await app.emit("message_end", { message: entry.message });
    // Pi persists a message only AFTER its message_end handlers have returned.
    app.branch([entry], entry.id);
    await app.emit("message_start", { message: { role: "assistant", content: [] } });
    expect(app.read()).toMatchObject({ name: "Latest request", leafId: "new-user", status: "busy" });
  });

  test("refreshes the record when a session is resumed in the same process", async () => {
    const app = harness();
    await app.emit("session_start", { reason: "startup" });
    app.session("session-b", "/different/session-b.jsonl");
    await app.emit("session_start", { reason: "resume" });
    expect(app.read()).toMatchObject({ sessionId: "session-b", sessionFile: "/different/session-b.jsonl" });
  });

  test("refreshes the name after rename", async () => {
    const app = harness();
    await app.emit("session_start", { reason: "startup" });
    app.name("New task name");
    await app.emit("session_info_changed", { name: "New task name" });
    expect(app.read().name).toBe("New task name");
  });

  test("uses the first user text as the name when unnamed", async () => {
    const app = harness();
    app.name(undefined);
    app.branch([{ type: "message", id: "prompt", parentId: null,
      message: { role: "user", content: [{ type: "image", data: "ignored" },
        { type: "text", text: "Fix\tthe bug\nwith tests" }] } }], "prompt");
    await app.emit("message_start");
    expect(app.read().name).toBe("Fix the bug with tests");
  });

  test("publishes an empty session without requiring a transcript file", async () => {
    const app = harness();
    app.name(undefined);
    app.branch([], null);
    await app.emit("session_start", { reason: "new" });
    expect(app.read().name).toBe("(new session)");
  });

  test("uses the empty-session label when the only user text is whitespace", async () => {
    const app = harness();
    app.name(undefined);
    app.branch([{ type: "message", id: "blank", parentId: null,
      message: { role: "user", content: " \n\t " } }], "blank");
    await app.emit("session_start", { reason: "startup" });
    expect(app.read().name).toBe("(new session)");
  });

  test("supports ephemeral sessions without inheriting a parent session file", async () => {
    const app = harness();
    app.session("ephemeral", undefined);
    await app.emit("session_start", { reason: "startup" });
    expect(app.read()).toMatchObject({ sessionId: "ephemeral", sessionFile: null });
  });

  test("marks the run busy and idle at the final settled boundary", async () => {
    const app = harness();
    await app.emit("session_start", { reason: "startup" });
    await app.emit("agent_start");
    expect(app.read().status).toBe("busy");
    await app.emit("agent_settled");
    expect(app.read().status).toBe("idle");
  });

  test("refreshes the active leaf on tree navigation", async () => {
    const app = harness();
    await app.emit("session_start", { reason: "startup" });
    app.branch([], "earlier-leaf");
    await app.emit("session_tree");
    expect(app.read().leafId).toBe("earlier-leaf");
  });

  test("removes its own record on shutdown and repeated cleanup is safe", async () => {
    const app = harness();
    await app.emit("session_start", { reason: "startup" });
    expect(existsSync(app.record)).toBe(true);
    await app.emit("session_shutdown", { reason: "reload" });
    await app.emit("session_shutdown", { reason: "quit" });
    expect(existsSync(app.record)).toBe(false);
  });

  for (const mode of ["rpc", "json", "print"]) {
    test(`never publishes ${mode} children with inherited tmux environment`, async () => {
      const app = harness(mode);
      await app.emit("session_start", { reason: "startup" });
      await app.emit("agent_start");
      await app.emit("message_start");
      expect(existsSync(app.record)).toBe(false);
    });
  }

  test("does not register terminal sessions outside tmux", async () => {
    delete process.env.TMUX;
    delete process.env.TMUX_PANE;
    const app = harness();
    await app.emit("session_start", { reason: "startup" });
    expect(existsSync(app.record)).toBe(false);
  });
});
