#!/usr/bin/env bash
# agent-switcher.sh — fuzzy-find running claude-code and opencode instances
# across tmux panes by thread name and jump to them. Bound to prefix+K.
#
# Data sources:
#   claude-code
#     ~/.claude/sessions/<pid>.json   — live session metadata (name, status, cwd)
#     ~/.claude/projects/<slug>/<sessionId>.jsonl — transcript (title, preview)
#   opencode
#     tmux pane title "OC | <title>"  — the session currently open in that pane
#     ~/.local/share/opencode/opencode.db — session id, status, transcript
#
# Tabs: 1 All · 2 Claude · 3 OpenCode (digits switch tabs while the query is
# empty, tab/shift-tab cycle). The initial tab follows the invoking pane: a
# claude pane opens on Claude, an opencode pane on OpenCode, anything else All.
#
# Usage:
#   agent-switcher.sh                  interactive fzf picker (run inside tmux or a popup)
#   agent-switcher.sh --list           print candidate rows (debugging)
#   agent-switcher.sh --preview <kind> <sessionId>   transcript preview (used by fzf)
#
# Internal (called back by fzf): --rows <kind>, --tab <n|next|prev>, --key <n>

set -uo pipefail

SELF="$0"
SESS_DIR="$HOME/.claude/sessions"
PROJECTS_DIR="$HOME/.claude/projects"
OC_DB="$HOME/.local/share/opencode/opencode.db"

KINDS=(all cc oc)
NAMES=(All Claude OpenCode)
PROMPTS=('  all ❯ ' '  claude ❯ ' '  opencode ❯ ')

ocq() { sqlite3 -readonly -separator $'\t' "$OC_DB" "$@" 2>/dev/null; }
sqlstr() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }

# ---------------------------------------------------------------- preview mode
if [[ "${1:-}" == "--preview" ]]; then
  kind="${2:-}" sid="${3:-}"
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

tab_label() {
  local active=$1 i out=""
  for i in 0 1 2; do
    local n style=$'\033[2m'
    n=$(filter_rows "${KINDS[i]}" | wc -l | tr -d ' ')
    (( i == active )) && style=$'\033[1;30;45m'
    out+="$style $((i + 1)) ${NAMES[i]} $n "$'\033[0m '
  done
  printf ' %s' "$out"
}

tab_action() {
  local i=$1
  echo "$i" >"$SWITCHER_STATE"
  printf 'reload-sync(%s --rows %s)+first+change-prompt(%s)+change-border-label(%s)' \
    "$SELF" "${KINDS[i]}" "${PROMPTS[i]}" "$(tab_label "$i")"
}

case "${1:-}" in
  --rows)
    filter_rows "${2:-all}"
    exit 0 ;;
  --tab)
    cur=$(cat "$SWITCHER_STATE" 2>/dev/null || echo 0)
    case "${2:-}" in
      next) i=$(( (cur + 1) % 3 )) ;;
      prev) i=$(( (cur + 2) % 3 )) ;;
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
# PANE: pane_pid -> pane_id, for mapping claude pids to panes. indexed array
# keyed by pid (numeric) — macOS ships bash 3.2, no declare -A.
# OC_PANES: panes that look like an opencode TUI, resolved further below.
PANE=()
OC_PANES=""
while IFS=$'\t' read -r ppid paneid pcmd cwd ptitle; do
  PANE[$ppid]="$paneid"
  if [[ "$pcmd" == opencode* || "$ptitle" == "OC | "* ]]; then
    OC_PANES+="$paneid"$'\t'"$cwd"$'\t'"$ptitle"$'\n'
  fi
done < <(tmux list-panes -a -F $'#{pane_pid}\t#{pane_id}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_title}')

short_path() {
  local p="$1"
  [[ "$p" == "$HOME"* ]] && p="~${p#"$HOME"}"
  printf '%s' "$p"
}

TAG_CC=$'\033[38;5;173mcc\033[0m'
TAG_OC=$'\033[38;5;110moc\033[0m'
BUSY=$'\033[1;33m●\033[0m'

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

  # real thread title: latest ai-title entry in transcript (set by claude's
  # auto-titling and /rename). fall back to the short derived name.
  title="$name"
  tf=$(ls "$PROJECTS_DIR"/*/"$sid".jsonl 2>/dev/null | head -1)
  if [[ -n "$tf" ]]; then
    t=$(grep '"type":"ai-title"' "$tf" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)
    [[ -n "$t" ]] && title="$t"
  fi

  st=' '
  [[ "$status" == "busy" ]] && st="$BUSY"
  display=$(printf '%s %s \033[1m%s\033[0m' "$st" "$TAG_CC" "$title")
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

    display=$(printf '%s %s \033[1m%s\033[0m' "$st" "$TAG_OC" "$title")
    rows+="oc"$'\t'"$updated"$'\t'"$paneid"$'\t'"${sid:-}"$'\t'"$display"$'\t'"$(short_path "$cwd")"$'\n'
  done <<<"${OC_PANES%$'\n'}"
fi

# most recently interacted first — fzf's default layout puts the first row at
# the bottom, right next to the search bar
rows=$(printf '%s' "$rows" | sort -t$'\t' -k2,2nr)

if [[ -z "$rows" ]]; then
  echo "no running claude-code or opencode instances found in tmux"
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
esac
echo "$tab" >"$SWITCHER_STATE"

sel=$("$SELF" --rows "${KINDS[tab]}" | fzf \
  --ansi \
  --delimiter=$'\t' \
  --with-nth=5 \
  --no-sort \
  --prompt="${PROMPTS[tab]}" \
  --border=top \
  --border-label="$(tab_label "$tab")" \
  --border-label-pos=1 \
  --bind="1:transform($SELF --key 1)" \
  --bind="2:transform($SELF --key 2)" \
  --bind="3:transform($SELF --key 3)" \
  --bind="tab:transform($SELF --tab next)" \
  --bind="shift-tab:transform($SELF --tab prev)" \
  --bind='focus:transform-header(echo wd: {6})' \
  --bind='result:transform-header(echo wd: {6})' \
  --header-first \
  --preview="$SELF --preview {1} {4}" \
  --preview-window='down,60%,wrap,follow' \
  --color='pointer:magenta,header:blue:underline,border:bright-black')

[[ -z "$sel" ]] && exit 0
paneid=$(cut -f3 <<<"$sel")

tmux switch-client -t "$paneid" 2>/dev/null || tmux attach -t "$paneid"
tmux select-window -t "$paneid"
tmux select-pane -t "$paneid"
