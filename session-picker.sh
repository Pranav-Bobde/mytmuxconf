#!/usr/bin/env bash
# Cmd+O session picker: a rounded dim card in the status-bar colors. The view
# name sits in the border title ("Sessions · switch"), a faint full-width band
# marks the selected row, and a muted peach dot marks attached sessions.
#
# Two views, Tab switches:
#   switch: existing sessions with their folders. Enter switches. Backspace on
#           an empty query deletes the highlighted session after a Yes/No
#           confirm (default No).
#   create: zoxide directories, or type a path. Enter creates a session there,
#           or switches to the session already rooted there (marked with a dot).
# Ctrl+J/K move down/up. Esc closes.
#
# Entry: session-picker.sh [client] [switch|create]
# tmux.conf passes #{client_name} so popups and switches target the right
# client when several are attached.
set -u

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# Catppuccin Mocha. Emphasis stays low: rows and selection are one or two grey
# steps apart, and the only warm color is a muted peach for attached sessions.
# BAND is surface0, the theme's selection color. Cell backgrounds render
# opaque over WezTerm's translucent wallpaper, and darker shades (base,
# #1e1e2e) read as a dark slab where the band crosses the bright silhouette.
DIM='#6c7086' FAINT='#585b70' ROW='#7f849c' SEL='#bac2de' TEXT='#cdd6f4' BAND='#313244' SURF='#45475a' WARM='#c99a7c'
THEME="fg:$ROW,fg+:$SEL:regular,bg:-1,bg+:$BAND,hl:$WARM,hl+:$WARM,pointer:$DIM,prompt:$DIM,query:$TEXT,info:$FAINT,header:$DIM,border:$BAND,label:$DIM,gutter:-1,separator:$BAND,scrollbar:$BAND"
# 24-bit ANSI for row and label text, matching the palette above.
C_WARM=$'\033[38;2;201;154;124m' C_FAINT=$'\033[38;2;88;91;112m' C_DIM=$'\033[38;2;108;112;134m' C_MODE=$'\033[38;2;166;173;200m' C_OFF=$'\033[0m'

# The border label names the view, and actions read it back from
# $FZF_BORDER_LABEL to know which view they run in.
LABEL_SWITCH=" ${C_DIM}Sessions · ${C_MODE}switch${C_OFF} "
LABEL_CREATE=" ${C_DIM}Sessions · ${C_MODE}create${C_OFF} "
HINT_SWITCH="↵ switch   ⌫ delete   tab → create    ${C_WARM}●${C_OFF} attached"
HINT_CREATE="↵ create or switch   tab → switch    ${C_WARM}●${C_OFF} has a session"

# Rows in both views are "value<TAB>display": fzf shows only the display
# column (--with-nth 2..), while {1} gives actions the raw session name or path.
list_switch() {
	tmux list-sessions -F "#{session_last_attached}	#{session_name}	#{session_windows}	#{session_attached}	#{session_path}" |
		sort -rn | cut -f2- |
		awk -F'\t' -v home="$HOME" -v warm="$C_WARM" -v faint="$C_FAINT" -v r="$C_OFF" '
			{ n[NR] = $1; w[NR] = $2 "w"; a[NR] = $3; p[NR] = $4; sub("^" home, "~", p[NR]); if (length($1) > m) m = length($1) }
			END { for (i = 1; i <= NR; i++)
				printf "%s\t%s%-*s  %s%-4s %s%s\n", n[i], (a[i] > 0 ? warm "● " r : "  "), m, n[i], faint, w[i], p[i], r }'
}

# Folders that already have a session get a dot and the session name, lined
# up in a column after the path (capped at 40 columns).
list_create() {
	zoxide query -l | awk -F'\t' -v home="$HOME" -v warm="$C_WARM" -v faint="$C_FAINT" -v r="$C_OFF" '
		NR == FNR { s[$1] = $2; next }
		{ n++; raw[n] = $0; d[n] = $0; sub("^" home, "~", d[n])
		  if (($0 in s) && length(d[n]) > w) w = length(d[n]) }
		END { if (w > 40) w = 40
			for (i = 1; i <= n; i++)
				if (raw[i] in s) printf "%s\t%s● %s%-*s  %s%s%s\n", d[i], warm, r, w, d[i], faint, s[raw[i]], r
				else printf "%s\t  %s\n", d[i], d[i] }' <(tmux list-sessions -F '#{session_path}	#{session_name}') -
}

expand() {
	case "$1" in
	"~") printf '%s\n' "$HOME" ;;
	"~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

say_error() {
	gum style --foreground 203 "$1"
	sleep 1.2
}

delete() {
	local name="$1"
	[ -n "$name" ] || return
	if [ "$(tmux list-sessions | wc -l)" -le 1 ]; then
		say_error "'$name' is the only session. Not deleting it."
		return
	fi
	gum confirm "Delete session '$name'?" --default=false --affirmative=Yes --negative=No \
		--prompt.foreground "$SEL" --selected.background "$SURF" --selected.foreground "$TEXT" \
		--unselected.background "$BAND" --unselected.foreground "$DIM" &&
		tmux kill-session -t "=$name"
}

create() {
	local client="$1" dir real name="" base n=2 spath sname
	dir="$(cd "$2" 2>/dev/null && pwd)" || return 1
	real="$(cd "$dir" && pwd -P)"
	# Reuse a session already rooted in this directory. Sessions store their
	# path as typed (symlinks, /tmp vs /private/tmp), so compare resolved paths.
	while IFS=$'\t' read -r spath sname; do
		if [ "$(cd "$spath" 2>/dev/null && pwd -P)" = "$real" ]; then
			name="$sname"
			break
		fi
	done < <(tmux list-sessions -F '#{session_path}	#{session_name}')
	if [ -z "$name" ]; then
		base="$(basename "$dir" | sed 's/^\.*//; s/[.:]/_/g')"
		base="${base:-session}"
		name="$base"
		while tmux has-session -t "=$name" 2>/dev/null; do
			name="$base-$n"
			n=$((n + 1))
		done
		tmux new-session -d -s "$name" -c "$dir"
	fi
	tmux switch-client -c "$client" -t "=$name"
}

enter() {
	local client="$1" label="$2" query="$3" pick="$4" dir
	if [ "$label" = "$LABEL_SWITCH" ]; then
		[ -n "$pick" ] && tmux switch-client -c "$client" -t "=$pick"
		return
	fi
	# A typed query counts as a path only when it looks like one; a plain word
	# is a fuzzy search, and resolving it against the popup's working directory
	# would pick a different folder than the highlighted row.
	case "$query" in
	/* | "~" | "~/"* | .*) dir="$(expand "$query")" ;;
	*) dir="" ;;
	esac
	[ -n "$dir" ] && [ -d "$dir" ] || dir="$(expand "$pick")"
	if [ -z "$dir" ] || ! create "$client" "$dir"; then
		say_error "Not a directory: ${query:-$pick}"
	fi
}

picker() {
	local client="$1" list=list_switch label="$LABEL_SWITCH" hints="$HINT_SWITCH" run="bash \"$self\""
	[ "$2" = create ] && list=list_create label="$LABEL_CREATE" hints="$HINT_CREATE"
	local in_switch="[ \"\$FZF_BORDER_LABEL\" = '$LABEL_SWITCH' ]"
	local toggle_view="if $in_switch; then
		echo 'change-border-label($LABEL_CREATE)+change-header($HINT_CREATE)+clear-query+reload($run _list create)'
	else
		echo 'change-border-label($LABEL_SWITCH)+change-header($HINT_SWITCH)+clear-query+reload($run _list switch)'
	fi"
	# The generated action must carry a literal {1} so fzf quotes the session
	# name itself when the action runs; printf builds it so the transform
	# template has no placeholder of its own to expand.
	local backspace="if $in_switch && [ -z \"\$FZF_QUERY\" ]; then
		printf 'execute(bash %q _delete {%s})+reload(bash %q _list switch)' '$self' 1 '$self'
	else
		echo backward-delete-char
	fi"
	"$list" | fzf \
		--ansi \
		--layout reverse \
		--border rounded \
		--border-label "$label" \
		--border-label-pos 3 \
		--prompt '› ' \
		--info default \
		--separator '─' \
		--header "$hints" \
		--color "$THEME" \
		--highlight-line \
		--pointer ' ' \
		--gutter ' ' \
		--no-scrollbar \
		--delimiter '\t' \
		--with-nth 2.. \
		--no-sort \
		--bind "ctrl-j:down,ctrl-k:up" \
		--bind "tab:transform:$toggle_view" \
		--bind "bspace:transform:$backspace" \
		--bind "enter:become($run _enter '$client' \"\$FZF_BORDER_LABEL\" {q} {1})"
}

case "${1:-}" in
_list) [ "${2:-}" = create ] && list_create || list_switch; exit ;;
_delete) delete "${2:-}"; exit ;;
_enter) enter "$2" "$3" "${4:-}" "${5:-}"; exit ;;
_fzf) picker "$2" "$3"; exit ;;
esac

client="${1:-$(tmux display -p '#{client_name}')}"
# fzf draws the border (-B drops tmux's) so Tab can relabel it.
tmux display-popup -c "$client" -E -B -w 60% -h 60% "bash '$self' _fzf '$client' '${2:-switch}'"
# Esc makes fzf exit non-zero; run-shell would print that in the status line.
exit 0
