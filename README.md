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

# Session picker (Cmd+O)

**Cmd+O** in WezTerm (or **prefix+o**) opens `session-picker.sh`: a rounded dim card in the status-bar colors. The border title names the view (`Sessions · switch`), a faint full-width band marks the selected row, and a muted `●` marks attached sessions.

- **switch** (default): existing sessions, most recent first, with window count and folder. Enter switches. Backspace on an empty search deletes the highlighted session after a Yes/No prompt (default No). The last remaining session can't be deleted, since that would stop the tmux server.
- **create**: zoxide directories, or type a path. Enter creates a session named after the folder, or switches to the session already rooted there (those rows show `●` and the session name).
- Tab toggles the views, Ctrl+J/K move, Esc closes.

Design notes:

- fzf draws the border (the popup uses `-B`) so Tab can relabel it. Actions read the view back from `$FZF_BORDER_LABEL`.
- The band is Catppuccin surface0 (`#313244`). Cell backgrounds render opaque over WezTerm's translucent wallpaper; darker shades read as a dark slab where the band crosses the wallpaper's bright areas.
- macOS `/bin/bash` is 3.2: under `set -u` an empty array is unbound. Expand optional arrays as `${a[@]+"${a[@]}"}`.

# Status bar

The bar sits at the bottom with plain text on the terminal background: dim grey windows, the current one with a peach number and bold name, the session name on the right. Catppuccin was removed; `tmux.conf` hardcodes the six Mocha colors it used to set (messages, copy mode, pane borders, clock). `status-right` must keep continuum's `#(continuum_save.sh)` hook, or autosave stops.

## Window list on Cmd hold

The window list appears only while Cmd is held in WezTerm. Neither WezTerm nor tmux sees Cmd pressed alone, so a watcher outside the terminal does it:

- `cmd-hold-watch` (Swift, LaunchAgent `xyz.pranavb.tmux-cmd-hold`, plist in `~/Library/LaunchAgents/`) polls the modifier state and frontmost app every 50 ms and runs `cmd-hold.sh on|off`. It only reads state and never intercepts key events, so other apps' global shortcuts keep working. About 0.3% CPU.
- `cmd-hold.sh off` swaps `status-format[0]` for a blank line that still runs the continuum hook. `on` resets `status-format` to tmux's default. The row keeps its height, so panes never resize.

Gotchas found while building it:

- A Karabiner rule remapping Cmd to Cmd (to detect the hold) broke every global shortcut (Raycast, Winkshot) while WezTerm was focused. Don't go back to that.
- `set -gu 'status-format[0]'` blanks that line instead of restoring the default. Unset the whole `status-format` option.
- In tmux 3.7, `status-bg terminal` falls back to `status-style` (default `bg=green`). Set `status-style` explicitly.

Install (the binary is built locally and git-ignored; the plist lives in `launchd/`):

```bash
swiftc -O -o ~/.config/tmux/cmd-hold-watch ~/.config/tmux/cmd-hold-watch.swift
cp ~/.config/tmux/launchd/xyz.pranavb.tmux-cmd-hold.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/xyz.pranavb.tmux-cmd-hold.plist
```

```bash
launchctl kickstart -k gui/$(id -u)/xyz.pranavb.tmux-cmd-hold   # restart after rebuilding
launchctl bootout gui/$(id -u)/xyz.pranavb.tmux-cmd-hold        # stop and unload (delete the plist to uninstall)
```
