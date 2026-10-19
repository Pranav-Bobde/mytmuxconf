#!/usr/bin/env bash
# fzf for extrakto (prefix+tab) in the card look. tmux.conf points
# @extrakto_fzf_tool here; extrakto's own arguments come last, so its layout,
# header and keys still win.
. "$(cd "$(dirname "$0")" && pwd)/popup-theme.sh"
exec fzf "${POPUP_FZF_OPTS[@]}" --border-label "$(popup_label Extract)" "$@"
