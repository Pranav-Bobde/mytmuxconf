#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_FZF_SCRIPTS="$CURRENT_DIR/plugins/tmux-fzf/scripts"

# Card look (popup-theme.sh) for the action list and tmux-fzf's sub-pickers.
# fzf-tmux -p hides tmux's popup border and lets fzf draw it, and tmux-fzf's
# .envs keeps an exported TMUX_FZF_OPTIONS, so window.sh inherits it.
. "$CURRENT_DIR/popup-theme.sh"
card_options() {
  printf -- '-p -w 62%% -h 38%% -m %s' "$(popup_fzf_args Window "$1" "$2")"
}
export TMUX_FZF_OPTIONS
TMUX_FZF_OPTIONS="$(card_options menu '↵ select   esc close')"

if [[ -f "$TMUX_FZF_SCRIPTS/.envs" ]]; then
  source "$TMUX_FZF_SCRIPTS/.envs"
fi

TMUX_FZF_BIN="${TMUX_FZF_BIN:-fzf}"
TMUX_FZF_OPTIONS="${TMUX_FZF_OPTIONS:-}"

action=$(printf "switch\nlink\nmove\nswap\nrename\nre-number\nkill\nwallpaper\n[cancel]" | eval "$TMUX_FZF_BIN $TMUX_FZF_OPTIONS")

if [[ -z "$action" || "$action" == "[cancel]" ]]; then
  exit 0
fi

if [[ "$action" == "re-number" ]]; then
  tmux move-window -r
elif [[ "$action" == "wallpaper" ]]; then
  # Own window, not a popup: tmux popups drop the sixel image previews.
  "$HOME/.config/wezterm/scripts/wallz" --window
else
  TMUX_FZF_OPTIONS="$(card_options "$action" '↵ select   tab mark   esc close')"
  bash "$TMUX_FZF_SCRIPTS/window.sh" "$action"
fi
