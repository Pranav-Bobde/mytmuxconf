"""Opt-in live Pi/fzf check in an isolated tmux server, without model requests.

Run: python3 tests/verify_live.py
Requires pi, tmux, fzf and jq on PATH. Existing user panes are never touched.
"""

import fcntl
import json
import os
from pathlib import Path
import pty
import shlex
import struct
import subprocess
import tempfile
import termios
import time
import uuid


REPO = Path(__file__).resolve().parents[1]
SOCKET = "pi-switcher-verify-" + uuid.uuid4().hex[:8]


def main():
    with tempfile.TemporaryDirectory(prefix="pi-switcher-live-") as directory:
        root = Path(directory)
        cache = root / "cache"
        sessions = root / "custom session's"
        sessions.mkdir()
        transcript = sessions / "verification.jsonl"
        timestamp = int(time.time() * 1000)
        entries = [
            {"type": "session", "version": 3, "id": "live-verification", "cwd": str(root),
             "timestamp": "2026-10-08T00:00:00.000Z"},
            {"type": "session_info", "id": "name", "parentId": None,
             "timestamp": "2026-10-08T00:00:00.000Z", "name": "Live Pi verification"},
            {"type": "message", "id": "user", "parentId": "name",
             "timestamp": "2026-10-08T00:00:01.000Z",
             "message": {"role": "user", "content": "Verify precise session mapping", "timestamp": timestamp}},
            {"type": "message", "id": "answer", "parentId": "user",
             "timestamp": "2026-10-08T00:00:02.000Z",
             "message": {"role": "assistant", "content": [{"type": "text", "text": "Exact transcript verified"}],
                         "api": "openai-responses", "provider": "openai", "model": "gpt-6-luna",
                         "stopReason": "stop", "timestamp": timestamp,
                         "usage": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
                                   "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}}},
        ]
        transcript.write_text("\n".join(map(json.dumps, entries)) + "\n")
        env = {**os.environ, "XDG_CACHE_HOME": str(cache), "PI_OFFLINE": "1", "PI_TELEMETRY": "0", "TERM": "xterm-256color"}
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        client = None
        master = None
        socket_file = None

        def tmux(*args, check=True):
            return subprocess.run(["tmux", "-L", SOCKET, *args], env=env, capture_output=True,
                                  text=True, timeout=15, check=check).stdout.strip()

        def wait_for(predicate, description):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if master is not None:
                    try:
                        while os.read(master, 65536):
                            pass
                    except BlockingIOError:
                        pass
                value = predicate()
                if value:
                    return value
                time.sleep(0.05)
            raise AssertionError(f"Timed out waiting for {description}")

        def metadata():
            files = list((cache / "tmux-agent-switcher/pi").glob("*.json"))
            if not files:
                return None
            return json.loads(files[0].read_text())

        def command(text):
            tmux("send-keys", "-t", pi_pane, "-l", text)
            tmux("send-keys", "-t", pi_pane, "Enter")

        def screen(pane):
            return tmux("capture-pane", "-p", "-t", pane)

        try:
            # Explicit extension path also exercises Pi's real TypeScript loader.
            pi_command = shlex.join([
                "pi", "--offline", "--no-approve", "--no-extensions", "--no-skills",
                "--no-prompt-templates", "--no-context-files", "--no-tools",
                "--extension", str(REPO / "pi-extension.ts"), "--session", str(transcript),
                "--session-dir", str(sessions),
            ])
            pi_pane = tmux("-f", "/dev/null", "new-session", "-d", "-s", "verify", "-c", str(root),
                           "-x", "120", "-y", "45", "-P", "-F", "#{pane_id}", pi_command)
            socket_file = Path(tmux("display-message", "-p", "#{socket_path}"))
            record = wait_for(metadata, "Pi session-start metadata")
            assert record["sessionFile"] == str(transcript), record
            assert record["name"] == "Live Pi verification", record
            # Startup can append model/thinking metadata after the answer.
            assert record["leafId"], record
            record_path = cache / "tmux-agent-switcher/pi" / f"{record['pid']}.json"
            env["TMUX"] = tmux("display-message", "-p", "#{socket_path},#{pid},0")
            env["SWITCHER_FROM"] = pi_pane

            rows = subprocess.check_output(["/bin/bash", str(REPO / "agent-switcher.sh"), "--list"],
                                           env=env, text=True, timeout=15).splitlines()
            assert len(rows) == 1 and rows[0].split("\t")[2:4] == [pi_pane, str(record_path)], rows
            preview = subprocess.check_output(["/bin/bash", str(REPO / "agent-switcher.sh"), "--preview", "pi", str(record_path)],
                                              env=env, text=True, timeout=15)
            assert "Exact transcript verified" in preview, preview
            print("PASS real Pi loader, exact custom session path, pane mapping, transcript preview")

            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 120, 0, 0))
            client = subprocess.Popen(["tmux", "-L", SOCKET, "attach-session", "-t", "verify"],
                                      stdin=slave, stdout=slave, stderr=slave, env=env)
            os.close(slave)
            os.set_blocking(master, False)
            wait_for(lambda: tmux("list-clients"), "isolated tmux client")
            picker_command = shlex.join(["env", f"SWITCHER_FROM={pi_pane}", "/bin/bash", str(REPO / "agent-switcher.sh")])
            picker_command += "; tmux wait-for -S picker-finished; exec /bin/sh"
            picker = tmux("new-window", "-t", "verify", "-n", "picker", "-c", str(root),
                          "-P", "-F", "#{pane_id}", picker_command)
            wait_for(lambda: "Exact transcript verified" in screen(picker), "fzf's real preview")
            assert "4 Pi 1" in screen(picker), screen(picker)
            tmux("send-keys", "-t", picker, "1")
            wait_for(lambda: "all ❯" in screen(picker), "All filter")
            tmux("send-keys", "-t", picker, "BTab")
            wait_for(lambda: "pi ❯" in screen(picker), "reverse wrap to Pi")
            tmux("send-keys", "-t", picker, "Tab")
            wait_for(lambda: "all ❯" in screen(picker), "forward wrap to All")
            tmux("send-keys", "-t", picker, "4")
            wait_for(lambda: "pi ❯" in screen(picker), "Pi digit filter")
            tmux("send-keys", "-t", picker, "Enter")
            tmux("wait-for", "picker-finished")
            assert tmux("list-clients", "-F", "#{pane_id}") == pi_pane
            print("PASS real fzf tabs, digit 4, active-branch preview and exact client/pane switch")

            command("/name Renamed live verification")
            wait_for(lambda: metadata()["name"] == "Renamed live verification", "rename event")
            original_id = metadata()["sessionId"]
            command("/new")
            wait_for(lambda: metadata()["sessionId"] != original_id, "new-session event")
            assert metadata()["name"] == "(new session)", metadata()
            updated = metadata()["updatedAt"]
            command("/reload")
            wait_for(lambda: metadata() and metadata()["updatedAt"] > updated, "extension reload")
            command("/resume")
            wait_for(lambda: "Renamed live verification" in screen(pi_pane), "resume picker")
            tmux("send-keys", "-t", pi_pane, "Enter")
            wait_for(lambda: metadata()["sessionId"] == original_id, "exact resumed session")
            print("PASS live rename, new session, /reload and /resume metadata updates")

            tmux("send-keys", "-t", pi_pane, "C-d")
            wait_for(lambda: not record_path.exists(), "graceful record cleanup")
            print("PASS live shutdown cleanup")
        finally:
            # Stop only our isolated server before reaping its PTY client.
            tmux("kill-server", check=False)
            if client is not None:
                try:
                    client.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=5)
            if master is not None:
                os.close(master)
            if socket_file is not None:
                socket_file.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
