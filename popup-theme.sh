# Shared look for every tmux popup (source it; it defines, never runs).
# The "card": a rounded dim border whose title names the popup and its current
# view ("Sessions · switch"), a dim › prompt, a counter line, hints in the
# header, a faint full-width band on the selected row, and a muted peach dot
# as the only warm accent. session-picker.sh is the reference implementation.
#
# Catppuccin Mocha, low emphasis: rows and selection are one or two grey steps
# apart. BAND is surface0, the theme's selection color. Cell backgrounds render
# opaque over WezTerm's translucent wallpaper, and darker shades (base,
# #1e1e2e) read as a dark slab where the band crosses the bright silhouette.
POPUP_DIM='#6c7086' POPUP_FAINT='#585b70' POPUP_ROW='#7f849c' POPUP_SEL='#bac2de'
POPUP_MODE='#a6adc8' POPUP_TEXT='#cdd6f4' POPUP_BAND='#313244' POPUP_SURF='#45475a'
POPUP_WARM='#c99a7c' POPUP_ERROR='#f38ba8'

POPUP_FZF_COLORS="fg:$POPUP_ROW,fg+:$POPUP_SEL:regular,bg:-1,bg+:$POPUP_BAND,hl:$POPUP_WARM,hl+:$POPUP_WARM,pointer:$POPUP_DIM,marker:$POPUP_WARM,prompt:$POPUP_DIM,query:$POPUP_TEXT,info:$POPUP_FAINT,header:$POPUP_DIM,border:$POPUP_BAND,label:$POPUP_DIM,gutter:-1,separator:$POPUP_BAND,scrollbar:$POPUP_BAND,preview-fg:$POPUP_ROW,preview-border:$POPUP_BAND,preview-label:$POPUP_DIM"

# 24-bit ANSI for row, hint and label text, matching the palette above.
C_WARM=$'\033[38;2;201;154;124m' C_FAINT=$'\033[38;2;88;91;112m' C_DIM=$'\033[38;2;108;112;134m'
C_MODE=$'\033[38;2;166;173;200m' C_OFF=$'\033[0m'

# fzf options for the card. Pair with `tmux display-popup -B` so fzf draws the
# only border (and Tab can relabel it with change-border-label).
POPUP_FZF_OPTS=(
	--ansi
	--layout reverse
	--border rounded
	--border-label-pos 3
	--prompt '› '
	--info default
	--separator '─'
	--color "$POPUP_FZF_COLORS"
	--highlight-line
	--pointer ' '
	--marker '•'
	--gutter ' '
	--no-scrollbar
)

# popup_label TITLE [VIEW] -> " Title · view " for --border-label.
popup_label() {
	if [ -n "${2:-}" ]; then
		printf ' %s%s · %s%s%s ' "$C_DIM" "$1" "$C_MODE" "$2" "$C_OFF"
	else
		printf ' %s%s%s ' "$C_DIM" "$1" "$C_OFF"
	fi
}

# popup_fzf_args TITLE VIEW HEADER -> the card options plus label and header as
# one shell-quoted string, for plugins that eval an options string (fzf-tmux,
# tmux-fzf, tmux-fzf-url). Single quotes keep UTF-8 intact; bash 3.2's
# printf %q mangles multibyte characters like › into invalid UTF-8.
popup_fzf_args() {
	local arg out=""
	for arg in "${POPUP_FZF_OPTS[@]}" --border-label "$(popup_label "$1" "$2")" --header "$3"; do
		out+="'$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")' "
	done
	printf '%s' "$out"
}

# popup_dot TEXT -> muted peach "● text" for hint legends and row markers.
popup_dot() { printf '%s●%s %s' "$C_WARM" "$C_OFF" "$1"; }

# tmux-drawn card for non-fzf popups (gum input): same border and title.
# Usage: tmux display-popup "${POPUP_TMUX_CARD[@]}" -T "$(popup_tmux_title Rename window)" ...
POPUP_TMUX_CARD=(-b rounded -S "fg=$POPUP_BAND")
popup_tmux_title() {
	if [ -n "${2:-}" ]; then
		printf '#[fg=%s] %s · #[fg=%s]%s ' "$POPUP_DIM" "$1" "$POPUP_MODE" "$2"
	else
		printf '#[fg=%s] %s ' "$POPUP_DIM" "$1"
	fi
}

# gum styling, exported so any gum call in a popup picks it up.
export GUM_INPUT_PROMPT="› " GUM_INPUT_PROMPT_FOREGROUND="$POPUP_DIM" \
	GUM_INPUT_CURSOR_FOREGROUND="$POPUP_TEXT" GUM_INPUT_HEADER_FOREGROUND="$POPUP_DIM" \
	GUM_INPUT_PLACEHOLDER_FOREGROUND="$POPUP_FAINT" GUM_INPUT_SHOW_HELP=false
export GUM_CONFIRM_PROMPT_FOREGROUND="$POPUP_SEL" GUM_CONFIRM_SELECTED_BACKGROUND="$POPUP_SURF" \
	GUM_CONFIRM_SELECTED_FOREGROUND="$POPUP_TEXT" GUM_CONFIRM_UNSELECTED_BACKGROUND="$POPUP_BAND" \
	GUM_CONFIRM_UNSELECTED_FOREGROUND="$POPUP_DIM"

# popup_error MESSAGE: show a short error inside the popup, then return.
popup_error() {
	gum style --foreground "$POPUP_ERROR" "$1"
	sleep 1.2
}
