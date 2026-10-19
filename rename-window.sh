#!/usr/bin/env bash
# Rename-window prompt (prefix+R, winmgr r) in the card look: tmux draws the
# rounded dim border and title, gum input takes the name. Empty input or Esc
# leaves the name unchanged.
#
# Entry: rename-window.sh <window-id> [client]
# tmux.conf passes #{window_id} so the window active at keypress is renamed.
set -u

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# shellcheck source=popup-theme.sh
. "$(dirname "$self")/popup-theme.sh"

if [ "${1:-}" = _input ]; then
	name="$(gum input --value "$(tmux display -p -t "$2" '#W')")" || exit 0
	[ -n "$name" ] && tmux rename-window -t "$2" -- "$name"
	exit 0
fi

window="${1:-$(tmux display -p '#{window_id}')}"
client="${2:-$(tmux display -p '#{client_name}')}"
tmux display-popup -c "$client" -E "${POPUP_TMUX_CARD[@]}" -T "$(popup_tmux_title Rename window)" \
	-w 50% -h 3 "bash '$self' _input '$window'"
exit 0
