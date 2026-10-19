#!/usr/bin/env bash
# Applies the card look (popup-theme.sh) to plugin popups by setting their
# tmux options. Run from tmux.conf; plugins read these options on each use.
. "$(cd "$(dirname "$0")" && pwd)/popup-theme.sh"

# tmux-fzf-url (prefix+u): options are eval'd after `fzf-tmux`, so quote them.
tmux set -g @fzf-url-fzf-options "-p 60%,30% $(popup_fzf_args URLs '' '↵ open   tab mark   esc close')"

# extrakto (prefix+tab) runs fzf through a wrapper that adds the card options.
# Its popup takes no border flags; tmux.conf sets popup-border-lines none so
# fzf's border is the only one.
tmux set -g @extrakto_fzf_tool "$HOME/.config/tmux/extrakto-fzf.sh" \; \
	set -g @extrakto_fzf_layout reverse
