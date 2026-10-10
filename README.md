# Terminal agent switcher

Press **Cmd+K** in WezTerm, or **prefix+K** in tmux, to find a running Claude Code, OpenCode, or Pi session and switch to its pane.

- `1` All, `2` Claude, `3` OpenCode, `4` Pi.
- Tab / Shift+Tab cycle filters. Digits select filters only when the search is empty.
- The picker starts on the invoking pane's agent filter.
- Rows show the session title and a busy marker. The preview shows recent user/assistant text.

## Pi setup

The canonical extension is `pi-extension.ts` in this repository. Install it once:

```bash
mkdir -p ~/.pi/agent/extensions
ln -s ~/.config/tmux/pi-extension.ts ~/.pi/agent/extensions/tmux-agent-switcher.ts
```

Run `/reload` in already-open Pi sessions. New sessions load the extension automatically.

The extension publishes the exact session file, active branch leaf, name, working directory, and status under `${XDG_CACHE_HOME:-~/.cache}/tmux-agent-switcher/pi/<pid>.json`. It writes only for interactive Pi inside tmux, uses atomic replacement and private permissions, and removes its record on shutdown or reload. Headless print/JSON/RPC sessions do not publish records.

The picker validates each Pi PID's process start time, then maps it to its tmux pane through process ancestry. A stale record cannot identify a different Pi that reused the PID. Two sessions in the same directory remain separate. Pi previews follow the recorded active branch and hide thinking, tool output, and abandoned branches. New and ephemeral sessions remain switchable without a transcript.

Before the extension loads, the picker can still list a foreground Pi process using its terminal title. This fallback has no busy status or transcript preview. It never guesses a session from the directory or most recent file. Dead records, non-Pi PIDs, and non-interactive records are ignored.

## Why a Pi extension

Pi's default terminal title contains a directory name, not a unique session identity. Pi also rewrites its process title to `pi` and closes the transcript between writes. Process/title-only discovery can find a pane, but cannot reliably choose its transcript. A small per-PID metadata bridge keeps that mapping exact while preserving the existing six-column picker format and Bash 3.2 compatibility.

The Cmd+K forwarding, popup binding, and tmux pane-selection commands are unchanged. This addition does not change tmux-resurrect support.

## Checks

```bash
cd ~/.config/tmux
python3 -m unittest discover -s tests -v
bun test tests/pi-extension.test.ts
bash -n agent-switcher.sh
./agent-switcher.sh --list
# Optional: real Pi and fzf in an isolated tmux server, no model requests.
python3 tests/verify_live.py
```

Python tests run the real picker with isolated terminal/process commands and real jq/text tools. Bun tests drive the real extension's lifecycle handlers and inspect its files. Neither suite sends input to existing user sessions.
