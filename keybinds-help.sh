#!/usr/bin/env bash
# Searchable cheatsheet of custom keybinds across tmux + wezterm.
# Parses the live configs, so new binds show up automatically.
# Bound to prefix+? (tmux popup). Run with --list to dump plain rows.
set -uo pipefail

# shellcheck source=popup-theme.sh
. "$(cd "$(dirname "$0")" && pwd)/popup-theme.sh"

TMUX_CONF="$HOME/.config/tmux/tmux.conf"
WEZ_CONF="$HOME/.config/wezterm/wezterm.lua"

# Friendly labels for binds whose raw action text is unreadable. Keyed "src|key".
describe() {
  case "$1" in
  "wezterm|cmd+[") echo "nvim jump back (ctrl+o)" ;;
  "wezterm|cmd+]") echo "nvim jump forward (ctrl+i)" ;;
  "wezterm|cmd+R") echo "nvim :source current file" ;;
  "wezterm|opt+h" | "wezterm|opt+j" | "wezterm|opt+k" | "wezterm|opt+l") echo "passthrough to tmux: pane nav" ;;
  "wezterm|opt+shift+h" | "wezterm|opt+shift+j" | "wezterm|opt+shift+k" | "wezterm|opt+shift+l") echo "passthrough to tmux: pane resize" ;;
  "tmux|prefix+o") echo "session picker: tab toggles switch/create (popup, cmd+o)" ;;
  "tmux|prefix+K") echo "agent session switcher: claude-code + opencode + Pi (fzf popup, cmd+k)" ;;
  "tmux|prefix+R" | "tmux|prefix+g r") echo "rename window (popup)" ;;
  "tmux|prefix+a") echo "sesh picker (popup)" ;;
  "tmux|prefix+P") echo "toggle directory path in status bar" ;;
  "tmux|prefix+w" | "tmux|prefix+W" | "tmux|prefix+g f") echo "window menu (fzf): switch, move pane, swap, rename, kill, wallpaper" ;;
  "tmux|prefix+g") echo "winmgr mode: h/l swap, j/k prev/next, r rename, n renumber, f menu, q quit" ;;
  "tmux|prefix+?") echo "this cheatsheet" ;;
  *) echo "" ;;
  esac
}

pretty_key() { # translate tmux key syntax to mac-ish labels
  local k=$1
  k=${k//M-/opt+}
  k=${k//C-/ctrl+}
  echo "$k"
}

tmux_binds() {
  grep -E '^[[:space:]]*bind(-key)?[[:space:]]' "$TMUX_CONF" | while IFS= read -r line; do
    set -f
    rest=${line#*bind}
    rest=${rest#-key}
    table="prefix"
    # shellcheck disable=SC2086
    set -- $rest
    while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do
      case $1 in
      -T)
        table=$2
        shift 2
        ;;
      -n)
        table="root"
        shift
        ;;
      *) shift ;;
      esac
    done
    key=${1:-}
    shift || true
    key=${key//\"/}
    action="$*"
    set +f
    [ "$table" = "copy-mode-vi" ] && continue
    case $table in
    prefix) label="prefix+$(pretty_key "$key")" ;;
    winmgr) label="prefix+g $key" ;;
    root) label="$(pretty_key "$key")" ;;
    *) label="$table:$key" ;;
    esac
    action=$(echo "$action" | tr -s ' ' | cut -c1-70)
    printf 'tmux\t%s\t%s\n' "$label" "$action"
  done
}

wez_binds() {
  perl -0777 -ne '
    while (/k\.(cmd|ctrl|opt)(_ctrl)?_to_tmux_prefix\(\s*["\x27](.+?)["\x27],\s*["\x27](.+?)["\x27]\s*\)\s*,?[ \t]*(?:--[ \t]*([^\n]*))?/g) {
      my ($mod, $ctrl, $key, $tkey, $desc) = ($1, $2, $3, $4, $5 // "");
      my $target = "tmux prefix+" . ($ctrl ? "ctrl+" : "") . $tkey;
      $target .= "  ($desc)" if $desc;
      print "wezterm\t$mod+$key\t$target\n";
    }
    while (/k\.(cmd|ctrl|opt)_key\(\s*\n?\s*["\x27](.+?)["\x27],\s*(.*?)\n?\s*\)\s*,/g) {
      my ($mod, $key, $act) = ($1, $2, $3);
      $act =~ s/\s+/ /g;
      print "wezterm\t$mod+$key\t" . substr($act, 0, 70) . "\n";
    }
    while (/k\.key_table\(\s*["\x27](.+?)["\x27],\s*["\x27](.+?)["\x27],\s*(.*?)\)\s*,/g) {
      my ($mods, $key, $act) = (lc($1), $2, $3);
      $mods =~ s/\|/+/g;
      $act =~ s/\s+/ /g;
      print "wezterm\t$mods+$key\t" . substr($act, 0, 70) . "\n";
    }
  ' "$WEZ_CONF"
}

# Plugin binds configured outside bind-key lines.
extras() {
  printf 'tmux\tprefix+tab\textrakto: fuzzy-pick text from pane\n'
  printf 'tmux\tprefix+u\tfzf-url: open URL from pane\n'
}

# Sorted, deduped "src<TAB>key<TAB>action" rows. Shared by --list and the card.
binds() {
  {
    tmux_binds
    wez_binds
    extras
  } | while IFS=$'\t' read -r src key act; do
    o=$(describe "$src|$key")
    [ -n "$o" ] && act=$o
    printf '%s\t%s\t%s\n' "$src" "$key" "$act"
  done | sort -t$'\t' -k1,1 -k2,2 | uniq
}

# --list: plain text, column-aligned. Output must not change.
rows() {
  binds | column -t -s$'\t'
}

# Card rows: ANSI colors. column -t counts escape bytes as width, so pad the
# plain text in awk first, then wrap the padded text in color.
card_rows() {
  binds | awk -F'\t' -v faint="$C_FAINT" -v dim="$C_DIM" -v r="$C_OFF" '
    { s[NR] = $1; k[NR] = $2; a[NR] = $3
      if (length($1) > ms) ms = length($1)
      if (length($2) > mk) mk = length($2) }
    END { for (i = 1; i <= NR; i++)
      printf "%s%-*s%s  %s%-*s%s  %s\n", faint, ms, s[i], r, dim, mk, k[i], r, a[i] }'
}

card() {
  card_rows | fzf "${POPUP_FZF_OPTS[@]}" \
    --border-label "$(popup_label Keybinds)" \
    --header 'type to filter   esc close' \
    --no-sort >/dev/null || true
}

if [ "${1:-}" = "--list" ]; then
  rows
else
  card
fi
