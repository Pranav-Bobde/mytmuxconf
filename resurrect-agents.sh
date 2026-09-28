#!/usr/bin/env bash
# resurrect-agents.sh <resurrect_save_file>
#
# tmux-resurrect post-save-layout hook. Makes AI-agent TUI panes survive a
# reboot by rewriting their saved command to resume the exact conversation.
#
# The process cannot survive a reboot, but the conversation does — both agents
# persist it to disk. All the saved command line is missing is the session id:
#
#   claude   --resume <uuid>     ~/.claude/projects/<slug>/<uuid>.jsonl
#   opencode -s <ses_...>        ~/.local/share/opencode/opencode.db
#
# Pane -> session id:
#   claude   — ~/.claude/sessions/<pid>.json holds {pid, sessionId}.
#   opencode — the TUI sets the terminal title to "OC | <session title>", which
#              tmux exposes as #{pane_title}. Look that up in opencode.db by
#              title + the pane's cwd; fall back to the newest root session for
#              that cwd if the title lookup misses.
#
# We also recompute the command line ourselves rather than trusting the value
# resurrect saved. Its default `ps` save strategy runs `pgrep -lf -P <pane_pid>`
# and joins EVERY child's command line, so a pane whose agent spawns helpers
# yields a spliced, unrunnable command. Reading the agent's own argv avoids
# that entirely and keeps unknown flags verbatim.
#
# A pane is only ever rewritten when a live agent process is its pane root or a
# direct child of it. That deliberately excludes an agent running nested inside
# something else (e.g. claude in an nvim :terminal) — there the pane belongs to
# nvim, and rewriting it would destroy the nvim entry that
# @resurrect-strategy-nvim is meant to restore.

set -uo pipefail

FILE="${1:-}"
[[ -f "$FILE" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CLAUDE_SESS_DIR="$HOME/.claude/sessions"
OPENCODE_DB="$HOME/.local/share/opencode/opencode.db"

MAP=$(mktemp) || exit 0
TMP="$FILE.agents.tmp"
trap 'rm -f "$MAP" "$TMP"' EXIT

# session_name / window_index / pane_index / pane_pid / pane_title / cwd
PANES=$(tmux list-panes -a -F \
  $'#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_pid}\t#{pane_title}\t#{pane_current_path}' \
  2>/dev/null | tr -d '\r')
[[ -n "$PANES" ]] || exit 0

# argv of $1, or empty. Guards against a stale sessions/<pid>.json whose pid has
# been recycled by an unrelated process.
agent_argv() {
  local pid="$1" want="$2" cmd
  cmd=$(ps -o command= -p "$pid" 2>/dev/null | tr -d '\t\n')
  [[ "$cmd" == "$want" || "$cmd" == "$want "* || "$cmd" == */"$want" || "$cmd" == */"$want "* ]] || return 1
  printf '%s' "$cmd"
}

# Pane whose root pid is $1, or whose root pid is the parent of $1. Prints
# "session<TAB>window<TAB>pane" or nothing.
pane_for_pid() {
  local pid="$1" ppid hit
  hit=$(awk -F'\t' -v p="$pid" '$4==p {print $1"\t"$2"\t"$3; exit}' <<<"$PANES")
  if [[ -z "$hit" ]]; then
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n "$ppid" && "$ppid" -gt 1 ]] || return 1
    hit=$(awk -F'\t' -v p="$ppid" '$4==p {print $1"\t"$2"\t"$3; exit}' <<<"$PANES")
  fi
  [[ -n "$hit" ]] && printf '%s' "$hit"
}

# ---------------------------------------------------------------- claude pass
if [[ -d "$CLAUDE_SESS_DIR" ]]; then
  for f in "$CLAUDE_SESS_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    IFS=$'\t' read -r pid sid kind < <(
      jq -r '[.pid, .sessionId, (.kind // "")] | @tsv' "$f" 2>/dev/null
    )
    [[ -n "${pid:-}" && -n "${sid:-}" && "${kind:-}" == "interactive" ]] || continue
    argv=$(agent_argv "$pid" claude) || continue
    hit=$(pane_for_pid "$pid") || continue
    [[ -n "$hit" ]] && printf '%s\t--resume\t%s\t%s\n' "$hit" "$sid" "$argv" >>"$MAP"
  done
fi

# -------------------------------------------------------------- opencode pass
if [[ -f "$OPENCODE_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
  while IFS=$'\t' read -r sess win pane ppid title cwd; do
    [[ "$title" == "OC | "* && -n "$cwd" ]] || continue

    # the opencode process must be the pane root or a direct child of it,
    # otherwise the title is stale and the pane has been repurposed
    argv=$(agent_argv "$ppid" opencode)
    if [[ -z "$argv" ]]; then
      for c in $(pgrep -P "$ppid" 2>/dev/null); do
        argv=$(agent_argv "$c" opencode) && break
      done
    fi
    [[ -n "$argv" ]] || continue

    t=${title#"OC | "}
    [[ -n "$t" ]] || continue
    # long titles are truncated with "…" — match those as a prefix
    if [[ "$t" == *"…" ]]; then
      t=${t%…}
      t=${t%"${t##*[![:space:]]}"}
      tq=${t//\'/\'\'}
      title_match="substr(title, 1, length('$tq')) = '$tq'"
    else
      tq=${t//\'/\'\'}
      title_match="title = '$tq'"
    fi
    dq=${cwd//\'/\'\'}

    sid=$(sqlite3 -readonly "$OPENCODE_DB" \
      "select id from session where parent_id is null and directory='$dq' \
       and $title_match order by time_updated desc limit 1;" 2>/dev/null)
    if [[ -z "$sid" ]]; then
      # title drifted (mid-regeneration, or the OSC format changed upstream)
      sid=$(sqlite3 -readonly "$OPENCODE_DB" \
        "select id from session where parent_id is null and directory='$dq' \
         order by time_updated desc limit 1;" 2>/dev/null)
    fi
    [[ -n "$sid" ]] && printf '%s\t%s\t%s\t-s\t%s\t%s\n' "$sess" "$win" "$pane" "$sid" "$argv" >>"$MAP"
  done <<<"$PANES"
fi

[[ -s "$MAP" ]] || exit 0

# ------------------------------------------------------------ rewrite savefile
# save-file pane fields:
#   1 line_type  2 session_name  3 window_number  4 window_active
#   5 window_flags  6 pane_index  7 pane_title  8 dir  9 pane_active
#   10 pane_command  11 pane_full_command (prefixed with ':')
awk -F'\t' -v OFS='\t' -v mapfile="$MAP" '
BEGIN {
  while ((getline line < mapfile) > 0) {
    n = split(line, a, "\t")
    if (n < 6) continue
    key = a[1] SUBSEP a[2] SUBSEP a[3]
    flag[key] = a[4]; sid[key] = a[5]; argv[key] = a[6]
  }
  # flags we replace with our own resume; the pair forms take a value, but
  # claude spells --resume with an OPTIONAL value, so only swallow the next
  # token when it is not itself a flag
  split("--resume -r --session -s", p, " ");  for (i in p) drop_pair[p[i]] = 1
  split("--continue -c --fork", b, " ");      for (i in b) drop_flag[b[i]] = 1
}

# Rebuild the agent command: program, our resume flag, then every original
# argument verbatim except the resume/continue family. Unknown flags and their
# values are preserved untouched — no whitelist to fall out of date.
function rebuild(cmd, resume_flag, resume_id,   n, t, i, out) {
  n = split(cmd, t, /[ \t]+/)
  out = ""
  for (i = 2; i <= n; i++) {
    if (t[i] == "") continue
    if (t[i] in drop_pair) {
      if (i < n && substr(t[i+1], 1, 1) != "-") i++
      continue
    }
    if (t[i] in drop_flag) continue
    out = out " " t[i]
  }
  return ":" t[1] " " resume_flag " " resume_id out
}

$1 == "pane" && NF == 11 {
  key = $2 SUBSEP $3 SUBSEP $6
  if (key in flag) $11 = rebuild(argv[key], flag[key], sid[key])
}
{ print }
' "$FILE" >"$TMP" || exit 0

# only replace the save file if the rewrite is intact — a truncated write (disk
# full) must never clobber a good save
[[ -s "$TMP" ]] || exit 0
[[ "$(wc -l <"$TMP")" -eq "$(wc -l <"$FILE")" ]] || exit 0
mv "$TMP" "$FILE"
