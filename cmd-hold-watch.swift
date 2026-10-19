// Shows the tmux window list while Cmd is held in WezTerm.
// Read-only: polls the global modifier state and the frontmost app, never
// intercepts or remaps key events, so other apps' shortcuts are unaffected.
// Needs no permissions. Runs as a LaunchAgent (xyz.pranavb.tmux-cmd-hold).
//
// Build: swiftc -O -o ~/.config/tmux/cmd-hold-watch ~/.config/tmux/cmd-hold-watch.swift
import AppKit

let script = NSString(string: "~/.config/tmux/cmd-hold.sh").expandingTildeInPath
let wezterm = "com.github.wez.wezterm"
var shown = false

func setBar(_ on: Bool) {
	shown = on
	let p = Process()
	p.executableURL = URL(fileURLWithPath: "/bin/bash")
	p.arguments = [script, on ? "on" : "off"]
	// Wait (~10 ms) so a quick on/off pair reaches tmux in order.
	try? p.run()
	p.waitUntilExit()
}

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
	let cmd = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
	let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == wezterm
	if cmd && front && !shown { setBar(true) }
	if (!cmd || !front) && shown { setBar(false) }
}

setBar(false)
RunLoop.main.run()
