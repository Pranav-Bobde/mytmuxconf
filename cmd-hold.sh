#!/usr/bin/env bash
# Show the window list only while Cmd is held in WezTerm.
# cmd-hold-watch (LaunchAgent) runs `cmd-hold.sh on` on Cmd down and
# `cmd-hold.sh off` on Cmd up; tmux.conf runs `off` at load.
# Hidden: status-format[0] keeps only the continuum autosave hook (it prints
# nothing, but continuum saves only when the status line runs it). The row
# keeps its height, so panes never resize. `on` restores the default formats.
tmux=/opt/homebrew/bin/tmux

case "${1:-}" in
on) "$tmux" set -gu status-format ;;
off) "$tmux" set -g 'status-format[0]' '#(~/.config/tmux/plugins/tmux-continuum/scripts/continuum_save.sh)' ;;
*) echo "usage: cmd-hold.sh on|off" >&2; exit 2 ;;
esac 2>/dev/null
