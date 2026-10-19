"""Behavioral tests for the real Bash 3.2 picker.

Run: python3 -m unittest discover -s tests -v
External terminal commands are isolated so tests never touch user panes.
"""

import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "agent-switcher.sh"



# The active tab is the one drawn in the card's brighter view-name color
# (C_MODE in popup-theme.sh) inside the border label.
ACTIVE_TAB = "\033[38;2;166;173;200m"


def border_label(args):
    return next(a for a in args if a.startswith("--border-label="))

class TabTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.rows = self.root / "rows"
        self.rows.write_text(
            "cc\t30\t%1\tclaude-id\tClaude task\t~/claude\n"
            "oc\t20\t%2\topencode-id\tOpenCode task\t~/opencode\n"
            "pi\t10\t%3\tpi-id\tPi task\t~/pi\n"
        )
        self.state = self.root / "tab"
        self.env = {
            **os.environ,
            "SWITCHER_ROWS": str(self.rows),
            "SWITCHER_STATE": str(self.state),
            "FZF_QUERY": "",
        }

    def run_script(self, *args):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), *args], env=self.env,
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_next_from_opencode_opens_pi(self):
        self.state.write_text("2\n")
        action = self.run_script("--tab", "next")
        self.assertEqual(self.state.read_text().strip(), "3")
        self.assertIn("--rows pi", action)
        self.assertIn(ACTIVE_TAB + "pi", action)

    def test_next_from_pi_wraps_to_all(self):
        self.state.write_text("3\n")
        self.assertIn("--rows all", self.run_script("--tab", "next"))
        self.assertEqual(self.state.read_text().strip(), "0")

    def test_previous_from_all_wraps_to_pi(self):
        self.state.write_text("0\n")
        self.assertIn("--rows pi", self.run_script("--tab", "prev"))
        self.assertEqual(self.state.read_text().strip(), "3")

    def test_four_opens_pi_for_empty_query(self):
        self.state.write_text("0\n")
        action = self.run_script("--key", "4")
        self.assertEqual(self.state.read_text().strip(), "3")
        self.assertIn("--rows pi", action)
        self.assertIn(ACTIVE_TAB + "pi", action)

    def test_four_is_search_text_for_nonempty_query(self):
        self.state.write_text("1\n")
        self.env["FZF_QUERY"] = "issue "
        self.assertEqual(self.run_script("--key", "4").strip(), "put(4)")
        self.assertEqual(self.state.read_text().strip(), "1")

    def test_pi_filter_keeps_only_pi_rows(self):
        self.assertEqual(
            self.run_script("--rows", "pi"),
            "pi\t10\t%3\tpi-id\tPi task\t~/pi\n",
        )


class PickerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.cache = self.root / "cache/tmux-agent-switcher/pi"
        self.cache.mkdir(parents=True)
        self.pid = os.getpid()
        self.fixture = {"panes": [], "processes": {}, "foreground": {}}
        self.env = {
            **os.environ, "HOME": str(self.root), "XDG_CACHE_HOME": str(self.root / "cache"),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "PICKER_FIXTURE": str(self.root / "fixture.json"), "SWITCHER_FROM": "%7",
        }
        self.command("tmux", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
f = json.loads(Path(os.environ["PICKER_FIXTURE"]).read_text())
if args[0] == "list-panes":
    fmt = args[args.index("-F") + 1]
    for p in f["panes"]:
        line = fmt
        for key, value in p.items():
            line = line.replace("#{" + key + "}", str(value))
        print(line)
elif args[0] == "display":
    print("%7")
elif args[0] != "info":
    with open(os.environ["PICKER_FIXTURE"] + ".calls", "a") as out:
        out.write(json.dumps(args) + "\\n")
''')
        self.command("ps", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
f = json.loads(Path(os.environ["PICKER_FIXTURE"]).read_text())
if "-t" in args:
    print(f["foreground"].get(args[args.index("-t") + 1], ""))
elif "-p" in args:
    p = f["processes"].get(args[args.index("-p") + 1], {})
    field = args[args.index("-o") + 1].rstrip("=")
    if field == "lstart" and f.get("require_utc") and os.environ.get("TZ") != "UTC":
        print("Thu Oct 8 00:00:00 2026")
    else:
        print(p.get(field, ""))
''')
        self.command("fzf", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
rows = sys.stdin.read()
Path(os.environ["PICKER_FIXTURE"] + ".fzf").write_text(json.dumps({"args": sys.argv[1:], "rows": rows}))
if os.environ.get("PICKER_SELECT"):
    for row in rows.splitlines():
        if row.split("\\t")[2] == os.environ["PICKER_SELECT"]:
            print(row)
            break
''')

    def command(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def pane(self, pane="%7", root_pid=100, title="π - project", command="node", tty="ttys001"):
        self.fixture["panes"].append({
            "pane_pid": root_pid, "pane_id": pane, "pane_current_command": command,
            "pane_current_path": "/workspace/project", "pane_title": title,
            "pane_tty": "/dev/" + tty,
        })
        self.fixture["foreground"][tty] = "S+ pi"
        self.fixture["processes"][str(root_pid)] = {"ppid": "1", "comm": "zsh", "command": "zsh"}

    def metadata(self, pid=None, pane_pid=100, **fields):
        pid = pid or self.pid
        self.fixture["processes"][str(pid)] = {"ppid": str(pane_pid), "comm": "pi", "command": "pi",
                                               "lstart": "Thu Oct 8 10:00:00 2026"}
        data = {"pid": pid, "mode": "tui", "processStartedAt": "Thu Oct 8 10:00:00 2026",
                "name": "Fix auth", "cwd": "/workspace/project",
                "sessionId": "session-a", "sessionFile": "/custom/session-a.jsonl", "leafId": "a",
                "status": "idle", "updatedAt": 1234, **fields}
        path = self.cache / f"{pid}.json"
        path.write_text(json.dumps(data))
        return path

    def run_script(self, *args):
        (self.root / "fixture.json").write_text(json.dumps(self.fixture))
        result = subprocess.run(["/bin/bash", str(SCRIPT), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def list_rows(self):
        return [line.split("\t") for line in self.run_script("--list").splitlines()
                if line.startswith(("pi\t", "cc\t", "oc\t"))]

    def test_lists_exact_pi_record_and_busy_state_once_per_pane(self):
        self.pane()
        record = self.metadata(status="busy")
        rows = self.list_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:4], ["pi", "1234", "%7", str(record)])
        self.assertIn("Fix auth", rows[0][4])
        self.assertIn("●", rows[0][4])
        self.assertEqual(len(rows[0]), 6)

    def test_live_pi_without_extension_is_listed_without_guessing_session(self):
        self.pane(title="π - Shared directory")
        rows = self.list_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:4], ["pi", "0", "%7", ""])
        self.assertIn("Shared directory", rows[0][4])

    def test_pi_fallback_sanitizes_tabs_in_title_without_losing_tty(self):
        self.pane(title="π - Shared\tdirectory")
        rows = self.list_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(rows[0]), 6)
        self.assertIn("Shared directory", rows[0][4])

    def test_pi_fallback_with_empty_title_keeps_tty(self):
        self.pane(title="")
        rows = self.list_rows()
        self.assertEqual(len(rows), 1)
        self.assertIn("(Pi session)", rows[0][4])

    def test_pi_process_start_check_is_independent_of_popup_timezone(self):
        self.pane()
        record = self.metadata()
        self.env["TZ"] = "Pacific/Honolulu"
        self.fixture["require_utc"] = True
        rows = self.list_rows()
        self.assertEqual(rows[0][3], str(record))

    def test_stale_title_without_foreground_pi_is_not_listed(self):
        self.pane()
        self.fixture["foreground"]["ttys001"] = "S+ node"
        self.assertEqual(self.list_rows(), [])

    def test_dead_pid_record_is_ignored(self):
        self.pane(command="zsh", title="shell")
        self.metadata(pid=2147483647)
        self.assertEqual(self.list_rows(), [])

    def test_reused_pid_record_for_a_non_pi_process_is_ignored(self):
        self.pane(command="zsh", title="shell")
        self.metadata()
        self.fixture["processes"][str(self.pid)]["comm"] = "python3"
        self.assertEqual(self.list_rows(), [])

    def test_stale_record_for_a_reused_pi_pid_falls_back_without_old_transcript(self):
        self.pane()
        self.metadata(processStartedAt="Wed Oct 7 10:00:00 2026", name="Old crashed session")
        rows = self.list_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:4], ["pi", "0", "%7", ""])
        self.assertNotIn("Old crashed session", rows[0][4])

    def test_headless_record_is_ignored_even_with_live_pid_and_tmux_ancestor(self):
        self.pane(command="zsh", title="shell")
        self.metadata(mode="json")
        self.assertEqual(self.list_rows(), [])

    def test_two_pi_sessions_in_the_same_directory_keep_exact_identity(self):
        other = subprocess.Popen(["sleep", "30"])
        self.addCleanup(other.wait)
        self.addCleanup(other.terminate)
        self.pane()
        self.pane(pane="%8", root_pid=200, tty="ttys002")
        first = self.metadata()
        second = self.metadata(pid=other.pid, pane_pid=200, sessionId="session-b", name="Fix billing", updatedAt=5678)
        rows = self.list_rows()
        self.assertEqual([(r[2], r[3]) for r in rows], [("%8", str(second)), ("%7", str(first))])

    def test_pi_pane_opens_the_pi_tab_with_four_binding(self):
        self.pane()
        self.metadata()
        self.run_script()
        self.assertTrue((self.root / "fixture.json.fzf").exists(), "Pi candidates should open fzf")
        captured = json.loads((self.root / "fixture.json.fzf").read_text())
        self.assertIn(ACTIVE_TAB + "pi", border_label(captured["args"]))
        self.assertTrue(any(arg.startswith("--bind=4:transform(") for arg in captured["args"]))
        self.assertTrue(captured["rows"].startswith("pi\t"))

    def test_selection_switches_to_exact_pane(self):
        self.pane()
        self.metadata()
        self.env["PICKER_SELECT"] = "%7"
        self.run_script()
        self.assertTrue((self.root / "fixture.json.calls").exists(), "Selecting Pi should switch the pane")
        calls = [json.loads(line) for line in (self.root / "fixture.json.calls").read_text().splitlines()]
        self.assertEqual(calls, [["switch-client", "-t", "%7"], ["select-window", "-t", "%7"],
                                 ["select-pane", "-t", "%7"]])

    def test_pi_preview_shows_only_text_on_active_branch(self):
        transcript = self.root / "session with 'quotes'.jsonl"
        entries = [
            {"type": "session", "id": "session-a", "version": 3},
            {"type": "message", "id": "u", "parentId": None, "message": {"role": "user", "content": "Fix auth"}},
            {"type": "message", "id": "abandoned", "parentId": "u", "message": {"role": "assistant", "content": [{"type": "text", "text": "Wrong branch"}]}},
            {"type": "message", "id": "a", "parentId": "u", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "Private thinking"}, {"type": "text", "text": "Auth fixed"}]}},
            {"type": "message", "id": "tool", "parentId": "a", "message": {"role": "toolResult", "content": [{"type": "text", "text": "Raw tool output"}]}},
        ]
        transcript.write_text("\n".join(map(json.dumps, entries)) + '\n{"partial":')
        record = self.metadata(sessionFile=str(transcript), leafId="tool")
        preview = self.run_script("--preview", "pi", str(record))
        self.assertIn("Fix auth", preview)
        self.assertIn("Auth fixed", preview)
        for hidden in ("Wrong branch", "Private thinking", "Raw tool output"):
            self.assertNotIn(hidden, preview)

    def test_pi_preview_reads_file_and_leaf_from_one_metadata_snapshot(self):
        old_file = self.root / "old.jsonl"
        new_file = self.root / "new.jsonl"
        for file, leaf, text in ((old_file, "old", "Old request"), (new_file, "new", "New request")):
            file.write_text(json.dumps({"type": "message", "id": leaf, "parentId": None,
                                       "message": {"role": "user", "content": text}}) + "\n")
        record = self.metadata(sessionFile=str(old_file), leafId="old")
        self.env.update({"PICKER_REAL_JQ": shutil.which("jq"), "PICKER_SWAP_RECORD": str(record),
                         "PICKER_NEW_FILE": str(new_file)})
        self.command("jq", '''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
result = subprocess.run([os.environ["PICKER_REAL_JQ"], *sys.argv[1:]])
record = Path(os.environ["PICKER_SWAP_RECORD"])
marker = record.with_suffix(".swapped")
if str(record) in sys.argv[1:] and not marker.exists():
    data = json.loads(record.read_text())
    data.update(sessionFile=os.environ["PICKER_NEW_FILE"], leafId="new")
    replacement = record.with_suffix(".swap")
    replacement.write_text(json.dumps(data))
    replacement.replace(record)
    marker.touch()
sys.exit(result.returncode)
''')
        preview = self.run_script("--preview", "pi", str(record))
        self.assertIn("Old request", preview)
        self.assertNotIn("New request", preview)

    def test_pi_preview_without_metadata_explains_reload(self):
        self.assertIn("/reload", self.run_script("--preview", "pi", ""))

    def test_pi_preview_for_ephemeral_session_has_clear_empty_state(self):
        record = self.metadata(sessionFile=None, leafId=None)
        self.assertIn("no transcript", self.run_script("--preview", "pi", str(record)))

    def test_malformed_metadata_uses_only_the_live_pane_fallback(self):
        self.pane()
        (self.cache / f"{self.pid}.json").write_text('{"pid":')
        rows = self.list_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:4], ["pi", "0", "%7", ""])

    def test_opencode_listing_preview_and_initial_tab_still_work(self):
        self.pane(pane="%8", root_pid=200, command="opencode", title="OC | OpenCode task", tty="ttys004")
        self.fixture["foreground"]["ttys004"] = "S+ opencode"
        self.pane()
        self.metadata()
        directory = self.root / ".local/share/opencode"
        directory.mkdir(parents=True)
        with sqlite3.connect(directory / "opencode.db") as db:
            db.executescript('''
                CREATE TABLE session (id TEXT, title TEXT, directory TEXT, parent_id TEXT, time_archived INTEGER, time_updated INTEGER);
                CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
                CREATE TABLE part (id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            ''')
            db.execute("INSERT INTO session VALUES (?, ?, ?, NULL, NULL, ?)",
                       ("oc-id", "OpenCode task", "/workspace/project", 8000))
            db.execute("INSERT INTO message VALUES (?, ?, ?, ?)",
                       ("m1", "oc-id", 7000, json.dumps({"role": "user"})))
            db.execute("INSERT INTO message VALUES (?, ?, ?, ?)",
                       ("m2", "oc-id", 8000, json.dumps({"role": "assistant", "time": {}})))
            for index, message, text in ((1, "m1", "OpenCode request"), (2, "m2", "OpenCode answer")):
                db.execute("INSERT INTO part VALUES (?, ?, ?, ?, ?)",
                           (f"p{index}", message, "oc-id", index, json.dumps({"type": "text", "text": text})))
        rows = self.list_rows()
        self.assertEqual([r[0] for r in rows], ["oc", "pi"])
        self.assertEqual(rows[0][:4], ["oc", "8000", "%8", "oc-id"])
        self.assertIn("●", rows[0][4])
        preview = self.run_script("--preview", "oc", "oc-id")
        self.assertIn("OpenCode request", preview)
        self.assertIn("OpenCode answer", preview)
        self.env["SWITCHER_FROM"] = "%8"
        self.run_script()
        captured = json.loads((self.root / "fixture.json.fzf").read_text())
        self.assertIn(ACTIVE_TAB + "opencode", border_label(captured["args"]))
        self.assertTrue(captured["rows"].startswith("oc\t"))
        self.assertNotIn("pi\t", captured["rows"])

    def test_claude_listing_and_preview_still_work(self):
        self.pane(command="claude", title="Claude", tty="ttys003")
        self.fixture["foreground"]["ttys003"] = "S+ claude"
        self.fixture["processes"][str(self.pid)] = {"command": "claude", "comm": "claude", "ppid": "100"}
        sessions = self.root / ".claude/sessions"
        sessions.mkdir(parents=True)
        (sessions / f"{self.pid}.json").write_text(json.dumps({"pid": self.pid, "sessionId": "cc-id", "status": "busy",
                "name": "fallback", "cwd": "/workspace/project", "kind": "interactive", "updatedAt": 9000}))
        project = self.root / ".claude/projects/project"
        project.mkdir(parents=True)
        (project / "cc-id.jsonl").write_text('\n'.join([
            '{"type":"ai-title","aiTitle":"Claude task"}',
            '{"type":"user","message":{"content":"Claude request"}}',
            '{"type":"assistant","message":{"content":[{"type":"text","text":"Claude answer"}]}}',
        ]))
        rows = self.list_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:4], ["cc", "9000", "%7", "cc-id"])
        self.assertIn("Claude task", rows[0][4])
        preview = self.run_script("--preview", "cc", "cc-id")
        self.assertIn("Claude request", preview)
        self.assertIn("Claude answer", preview)


if __name__ == "__main__":
    unittest.main()
