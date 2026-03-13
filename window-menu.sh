#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_FZF_SCRIPTS="$CURRENT_DIR/plugins/tmux-fzf/scripts"

if [[ -f "$TMUX_FZF_SCRIPTS/.envs" ]]; then
  source "$TMUX_FZF_SCRIPTS/.envs"
fi

TMUX_FZF_BIN="${TMUX_FZF_BIN:-fzf}"
TMUX_FZF_OPTIONS="${TMUX_FZF_OPTIONS:-}"

FZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS --header='Select an action.'"
action=$(printf "switch\nlink\nmove\nswap\nrename\nre-number\nkill\n[cancel]" | eval "$TMUX_FZF_BIN $TMUX_FZF_OPTIONS")

if [[ -z "$action" || "$action" == "[cancel]" ]]; then
  exit 0
fi

if [[ "$action" == "re-number" ]]; then
  tmux move-window -r
else
  bash "$TMUX_FZF_SCRIPTS/window.sh" "$action"
fi
