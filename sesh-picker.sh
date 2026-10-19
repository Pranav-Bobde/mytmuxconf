#!/usr/bin/env bash
# prefix+a sesh picker in the card look (popup-theme.sh): sesh's sessions,
# configs and zoxide folders with their icons. Enter connects. sesh strips the
# icon prefix from the picked line itself, so the line is passed as-is.
#
# Entry: sesh-picker.sh [client]
set -u

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# shellcheck source=popup-theme.sh
. "$(dirname "$self")/popup-theme.sh"

if [ "${1:-}" = _fzf ]; then
	pick="$(sesh list -i | fzf "${POPUP_FZF_OPTS[@]}" \
		--border-label "$(popup_label Sesh)" \
		--header '↵ connect   esc close' \
		--no-sort)" || exit 0
	sesh connect "$pick"
	exit
fi

client="${1:-$(tmux display -p '#{client_name}')}"
tmux display-popup -c "$client" -E -B -w 50% -h 50% "bash '$self' _fzf"
# Esc makes fzf exit non-zero; run-shell would print that in the status line.
exit 0
