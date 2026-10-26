#!/usr/bin/env bash
# agent-switcher.sh — fuzzy-find running claude-code, opencode and Pi instances
# across tmux panes by thread name and jump to them. Bound to prefix+K.
#
# Data sources:
#   claude-code
#     ~/.claude/sessions/<pid>.json   — live session metadata (name, status, cwd)
#     ~/.claude/projects/<slug>/<sessionId>.jsonl — transcript (title, preview)
#   opencode
#     tmux pane title "OC | <title>"  — the session currently open in that pane
#     ~/.local/share/opencode/opencode.db — session id, status, transcript
#   Pi
#     pi-extension.ts — live TUI metadata in $XDG_CACHE_HOME/tmux-agent-switcher/pi
#     exact session JSONL + active leaf — title, status, branch-aware preview
#     live foreground Pi process — pane-only fallback until /reload
#
# Tabs: 1 All · 2 Claude · 3 OpenCode · 4 Pi (digits switch tabs while the query
# is empty, tab/shift-tab cycle). The initial tab follows the invoking agent.
#
# Usage:
#   agent-switcher.sh                  interactive fzf picker (run inside tmux or a popup)
#   agent-switcher.sh --list           print candidate rows (debugging)
#   agent-switcher.sh --preview <kind> <sessionRef>  transcript preview (used by fzf)
#     sessionRef is a session ID for cc/oc, a live metadata file for Pi
#
# Internal (called back by fzf): --rows <kind>, --tab <n|next|prev>, --key <n>

set -uo pipefail

SELF="$0"
SESS_DIR="$HOME/.claude/sessions"
PROJECTS_DIR="$HOME/.claude/projects"
OC_DB="$HOME/.local/share/opencode/opencode.db"
PI_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-switcher/pi"

KINDS=(all cc oc pi)
TABS=(all claude opencode pi)

# shellcheck source=popup-theme.sh
. "$(cd "$(dirname "$0")" && pwd)/popup-theme.sh"

ocq() { sqlite3 -readonly -separator $'\t' "$OC_DB" "$@" 2>/dev/null; }
sqlstr() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }

# ---------------------------------------------------------------- preview mode
if [[ "${1:-}" == "--preview" ]]; then
  kind="${2:-}" sid="${3:-}"
  if [[ "$kind" == "pi" ]]; then
    [[ -z "$sid" ]] && { echo "Run /reload in this Pi pane to enable its session preview."; exit 0; }
    # Read one atomic snapshot so a session switch cannot mix its file and leaf.
    f="" leaf=""
    {
      IFS= read -r -d '' f
      IFS= read -r -d '' leaf
    } < <(jq -j '(.sessionFile // ""), "\u0000", (.leafId // ""), "\u0000"' "$sid" 2>/dev/null)
    [[ ! -r "$f" || -z "$leaf" ]] && { echo "no transcript yet (new or ephemeral session)"; exit 0; }
    # Follow the recorded leaf, not the last physical entry: /tree can leave
    # newer messages on an abandoned branch. Ignore an in-progress JSONL line.
    jq -Rrs --arg leaf "$leaf" '
      split("\n") | map(fromjson? | select(.type != "session" and .id != null))
      | INDEX(.id) as $entries
      | $entries[$leaf]
      | [while(. != null; if .parentId == null then null else $entries[.parentId] end)]
      | reverse | .[-80:][]
      | select(.type == "message" and (.message.role == "user" or .message.role == "assistant"))
      | .message.role as $role
      | (.message.content
         | if type == "string" then .
           else ([.[]? | select(.type == "text") | .text] | join("\n")) end) as $text
      | select($text != null and $text != "")
      | (if $role == "user" then "\u001b[1;33m● you\u001b[0m"
         else "\u001b[1;36m● pi\u001b[0m" end)
        + "\n" + ($text | .[0:1500]) + "\n"
    ' "$f" 2>/dev/null | tail -n 120
    exit 0
  fi
  [[ -z "$sid" ]] && { echo "no session yet"; exit 0; }

  if [[ "$kind" == "oc" ]]; then
    ocq -json "
      select json_extract(m.data, '\$.role') as role,
             json_extract(p.data, '\$.text') as text
      from part p join message m on m.id = p.message_id
      where p.session_id = $(sqlstr "$sid")
        and json_extract(p.data, '\$.type') = 'text'
        and coalesce(json_extract(p.data, '\$.synthetic'), 0) = 0
      order by p.time_created desc, p.id desc
      limit 80" | jq -r '
      reverse | .[]
      | select(.text != null and .text != "")
      | (if .role == "user"
         then "\u001b[1;33m● you\u001b[0m"
         else "\u001b[1;36m● opencode\u001b[0m" end)
        + "\n" + (.text | .[0:1500]) + "\n"
    ' 2>/dev/null | tail -n 120
    exit 0
  fi

  f=$(ls "$PROJECTS_DIR"/*/"$sid".jsonl 2>/dev/null | head -1)
  if [[ -z "$f" ]]; then
    echo "no transcript found"
    exit 0
  fi
  tail -n 400 "$f" | jq -r '
    select(.type == "user" or .type == "assistant")
    | select(.isMeta != true)
    | .type as $role
    | (.message.content
       | if type == "string" then .
         else ([.[]? | select(.type == "text") | .text] | join("\n"))
         end) as $t
    | select($t != null and $t != "" and ($t | startswith("<") | not))
    | (if $role == "user"
       then "\u001b[1;33m● you\u001b[0m"
       else "\u001b[1;36m● claude\u001b[0m" end)
      + "\n" + ($t | .[0:1500]) + "\n"
  ' 2>/dev/null | tail -n 120
  exit 0
fi

# ------------------------------------------------- fzf callbacks (tab switching)
# rows live in $SWITCHER_ROWS, current tab index in $SWITCHER_STATE (both set below)
filter_rows() {
  awk -F'\t' -v k="$1" 'k == "all" || $1 == k' "$SWITCHER_ROWS"
}

# Border title: "Agents · all · claude · opencode · pi", the active tab one grey
# step brighter (the card's view-name style, see popup-theme.sh).
tab_label() {
  local active=$1 i out=" ${C_DIM}Agents"
  for i in "${!KINDS[@]}"; do
    out+=" ${C_DIM}· "
    if (( i == active )); then out+="$C_MODE"; else out+="$C_FAINT"; fi
    out+="${TABS[i]}"
  done
  printf '%s %s' "$out" "$C_OFF"
}

tab_action() {
  local i=$1
  echo "$i" >"$SWITCHER_STATE"
  printf 'reload-sync(%s --rows %s)+first+change-border-label(%s)' \
    "$SELF" "${KINDS[i]}" "$(tab_label "$i")"
}

case "${1:-}" in
  --rows)
    filter_rows "${2:-all}"
    exit 0 ;;
  --tab)
    cur=$(cat "$SWITCHER_STATE" 2>/dev/null || echo 0)
    case "${2:-}" in
      next) i=$(( (cur + 1) % ${#KINDS[@]} )) ;;
      prev) i=$(( (cur + ${#KINDS[@]} - 1) % ${#KINDS[@]} )) ;;
      *)    i=$(( ${2:-1} - 1 )) ;;
    esac
    tab_action "$i"
    exit 0 ;;
  --key)
    # digits switch tabs only while the query is empty; otherwise type them
    if [[ -n "${FZF_QUERY:-}" ]]; then
      printf 'put(%s)' "$2"
    else
      tab_action $(( $2 - 1 ))
    fi
    exit 0 ;;
esac

command -v jq >/dev/null || { echo "agent-switcher: jq not found" >&2; exit 1; }
command -v fzf >/dev/null || { echo "agent-switcher: fzf not found" >&2; exit 1; }
command -v tmux >/dev/null || { echo "agent-switcher: tmux not found" >&2; exit 1; }
tmux info >/dev/null 2>&1 || { echo "agent-switcher: no tmux server running" >&2; exit 1; }

# pane the picker was invoked from (inside a popup this resolves to the pane
# underneath it)
FROM_PANE="${SWITCHER_FROM:-$(tmux display -p '#{pane_id}' 2>/dev/null)}"

# ------------------------------------------------------------ scan tmux panes
# PANE: pane_pid -> pane_id, for mapping agent pids to panes. indexed array
# keyed by pid (numeric) — macOS ships bash 3.2, no declare -A.
# OC_PANES: panes that look like an opencode TUI, resolved further below.
PANE=()
OC_PANES=""
PI_PANES=""
while IFS=$'\t' read -r ppid paneid pcmd cwd ptty ptitle; do
  PANE[$ppid]="$paneid"
  if [[ "$pcmd" == opencode* || "$ptitle" == "OC | "* ]]; then
    OC_PANES+="$paneid"$'\t'"$cwd"$'\t'"$ptitle"$'\n'
  fi
  if [[ "$pcmd" == node || "$pcmd" == pi || "$ptitle" == "π - "* ]]; then
    PI_PANES+="$paneid"$'\t'"$cwd"$'\t'"$ptty"$'\t'"$ptitle"$'\n'
  fi
done < <(tmux list-panes -a -F $'#{pane_pid}\t#{pane_id}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_tty}\t#{pane_title}')

short_path() {
  local p="$1"
  [[ "$p" == "$HOME"* ]] && p="~${p#"$HOME"}"
  printf '%s' "$p"
}

# Pi records carry PIDs, never a trusted/inherited TMUX_PANE identity.
pane_for_pid() {
  local p="$1" depth
  for (( depth=0; depth<64; depth++ )); do
    [[ -z "$p" || "$p" == *[!0-9]* || "$p" -le 1 ]] && return 1
    if [[ -n "${PANE[$p]:-}" ]]; then printf '%s' "${PANE[$p]}"; return 0; fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

clean_title() {
  printf '%s' "$1" | tr -d '\000-\010\013-\037\177' | tr '\t\n' '  '
}

TAG_CC="${C_FAINT}cc$C_OFF"
TAG_OC="${C_FAINT}oc$C_OFF"
TAG_PI="${C_FAINT}pi$C_OFF"
BUSY="${C_WARM}●$C_OFF"

# rows: kind \t updated \t paneid \t sid \t display \t cwd
rows=""

# ----------------------------------------- claude-code: running sessions
for f in "$SESS_DIR"/*.json; do
  [[ -e "$f" ]] || continue
  IFS=$'\t' read -r pid sid status name cwd kind updated < <(
    jq -r '[.pid, .sessionId, .status, .name, .cwd, .kind, (.updatedAt // 0)] | @tsv' "$f" 2>/dev/null
  )
  [[ -z "${pid:-}" || "$kind" != "interactive" ]] && continue
  kill -0 "$pid" 2>/dev/null || continue
  ps -o command= -p "$pid" 2>/dev/null | grep -qi claude || continue

  # walk ancestors of the claude pid until we hit a tmux pane root pid
  p="$pid" paneid=""
  for _ in 1 2 3 4 5 6 7 8; do
    [[ -z "$p" || "$p" -le 1 ]] && break
    if [[ -n "${PANE[$p]:-}" ]]; then paneid="${PANE[$p]}"; break; fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  [[ -z "$paneid" ]] && continue

  # real thread title from the transcript: the latest /rename (custom-title)
  # wins, since claude keeps appending ai-title entries after a rename; then
  # the latest auto title (ai-title); then the short derived name.
  title="$name"
  tf=$(ls "$PROJECTS_DIR"/*/"$sid".jsonl 2>/dev/null | head -1)
  if [[ -n "$tf" ]]; then
    t=$(grep '"type":"custom-title"' "$tf" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
    [[ -z "$t" ]] && t=$(grep '"type":"ai-title"' "$tf" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)
    [[ -n "$t" ]] && title="$t"
  fi

  st=' '
  [[ "$status" == "busy" ]] && st="$BUSY"
  display=$(printf '%s %s %s' "$st" "$TAG_CC" "$title")
  rows+="cc"$'\t'"$updated"$'\t'"$paneid"$'\t'"$sid"$'\t'"$display"$'\t'"$(short_path "$cwd")"$'\n'
done

# ----------------------------------------- opencode: panes running the TUI
# opencode has no per-process session file; its TUI sets the pane title to
# "OC | <session title>" (truncated with "…"), which we resolve against the db
if [[ -n "$OC_PANES" && -r "$OC_DB" ]] && command -v sqlite3 >/dev/null; then
  while IFS=$'\t' read -r paneid cwd ptitle; do
    title="(new session)" sid="" updated=0 st=' '
    if [[ "$ptitle" == "OC | "* ]]; then
      title="${ptitle#OC | }"
      if [[ "$title" == *"…" ]]; then
        prefix="${title%…}"
        prefix="${prefix%"${prefix##*[![:space:]]}"}"
        match="substr(title, 1, length($(sqlstr "$prefix"))) = $(sqlstr "$prefix")"
      else
        match="title = $(sqlstr "$title")"
      fi
      IFS=$'\t' read -r sid full updated role completed < <(ocq "
        select s.id, s.title, s.time_updated,
               coalesce(json_extract(m.data, '\$.role'), ''),
               coalesce(json_extract(m.data, '\$.time.completed'), '')
        from (select * from session
              where parent_id is null and time_archived is null and $match
              order by (directory = $(sqlstr "$cwd")) desc, time_updated desc
              limit 1) s
        left join message m on m.id = (
          select id from message where session_id = s.id
          order by time_created desc, id desc limit 1)")
      [[ -n "${full:-}" ]] && title="$full"
      [[ "${role:-}" == "assistant" && -z "${completed:-}" ]] && st="$BUSY"
      updated="${updated:-0}"
    fi

    display=$(printf '%s %s %s' "$st" "$TAG_OC" "$title")
    rows+="oc"$'\t'"$updated"$'\t'"$paneid"$'\t'"${sid:-}"$'\t'"$display"$'\t'"$(short_path "$cwd")"$'\n'
  done <<<"${OC_PANES%$'\n'}"
fi

# ------------------------------------------------ Pi: exact live TUI records
PI_SEEN="|"
for f in "$PI_DIR"/*.json; do
  [[ -r "$f" ]] || continue
  if ! IFS=$'\t' read -r pid status title cwd updated started < <(jq -er '
    select(.mode == "tui" and (.pid | type) == "number"
      and (.cwd | type) == "string" and .cwd != ""
      and (.processStartedAt | type) == "string" and .processStartedAt != "")
    | [.pid, (.status // "idle"),
       (if (.name // "") == "" then "(new session)" else .name end), .cwd, (.updatedAt // 0), .processStartedAt]
    | map(if type == "string" then gsub("[[:cntrl:]]"; " ") else . end) | @tsv
  ' "$f" 2>/dev/null); then continue; fi
  [[ "$pid" == *[!0-9]* || "$pid" -le 1 || "$f" != "$PI_DIR/$pid.json" ]] && continue
  kill -0 "$pid" 2>/dev/null || continue
  pcmd=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  [[ "${pcmd##*/}" == pi ]] || continue
  # A crashed Pi can leave a record whose PID later belongs to another Pi.
  actual_start=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')
  [[ -n "$actual_start" && "$actual_start" == "$started" ]] || continue
  paneid=$(pane_for_pid "$pid") || continue
  [[ "$PI_SEEN" == *"|$paneid|"* ]] && continue
  PI_SEEN+="$paneid|"
  st=' '
  [[ "$status" == "busy" ]] && st="$BUSY"
  display=$(printf '%s %s %s' "$st" "$TAG_PI" "$(clean_title "$title")")
  # Pi field 4 is the metadata reference, which includes the exact file + leaf.
  rows+="pi"$'\t'"$updated"$'\t'"$paneid"$'\t'"$f"$'\t'"$display"$'\t'"$(short_path "$cwd")"$'\n'
done

# Existing Pi panes can be switched to before loading the extension. Require
# a foreground Pi process on the pane TTY; a stale title or plain node is not Pi.
if [[ -n "$PI_PANES" ]]; then
  while IFS=$'\t' read -r paneid cwd ptty title; do
    [[ "$PI_SEEN" == *"|$paneid|"* ]] && continue
    [[ -n "$ptty" ]] || continue
    ps -t "${ptty#/dev/}" -o stat=,comm= 2>/dev/null | awk '
      $1 ~ /\+/ && $2 ~ /(^|\/)pi$/ { found=1 } END { exit !found }
    ' || continue
    title="${title#π - }"
    [[ -n "$title" ]] || title="(Pi session)"
    display=$(printf '  %s %s' "$TAG_PI" "$(clean_title "$title")")
    rows+="pi"$'\t'"0"$'\t'"$paneid"$'\t\t'"$display"$'\t'"$(short_path "$cwd")"$'\n'
  done <<<"${PI_PANES%$'\n'}"
fi

# most recently interacted first — the card's reverse layout puts the first row
# at the top, right under the search bar
rows=$(printf '%s' "$rows" | sort -t$'\t' -k2,2nr)

if [[ -z "$rows" ]]; then
  echo "no running claude-code, opencode or Pi instances found in tmux"
  read -r -n1 -s -p "press any key" 2>/dev/null || true
  exit 0
fi

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "$rows"
  exit 0
fi

SWITCHER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-switcher.XXXXXX")
trap 'rm -rf "$SWITCHER_TMP"' EXIT
export SWITCHER_ROWS="$SWITCHER_TMP/rows" SWITCHER_STATE="$SWITCHER_TMP/tab"
printf '%s\n' "$rows" >"$SWITCHER_ROWS"

# initial tab: whatever kind of agent lives in the invoking pane, else All
tab=0
from_kind=$(awk -F'\t' -v p="$FROM_PANE" '$3 == p { print $1; exit }' "$SWITCHER_ROWS")
case "$from_kind" in
  cc) tab=1 ;;
  oc) tab=2 ;;
  pi) tab=3 ;;
esac
echo "$tab" >"$SWITCHER_STATE"

sel=$("$SELF" --rows "${KINDS[tab]}" | fzf "${POPUP_FZF_OPTS[@]}" \
  --delimiter=$'\t' \
  --with-nth=5 \
  --no-sort \
  --border-label="$(tab_label "$tab")" \
  --header="1-4 or tab  change tab   ↵ jump    $(popup_dot busy)" \
  --bind="1:transform($SELF --key 1)" \
  --bind="2:transform($SELF --key 2)" \
  --bind="3:transform($SELF --key 3)" \
  --bind="4:transform($SELF --key 4)" \
  --bind="tab:transform($SELF --tab next)" \
  --bind="shift-tab:transform($SELF --tab prev)" \
  --bind='focus:transform-preview-label(echo " {6} ")' \
  --preview="$SELF --preview {1} {4}" \
  --preview-window='down,60%,wrap,follow,border-top')

[[ -z "$sel" ]] && exit 0
paneid=$(cut -f3 <<<"$sel")

tmux switch-client -t "$paneid" 2>/dev/null || tmux attach -t "$paneid"
tmux select-window -t "$paneid"
tmux select-pane -t "$paneid"
