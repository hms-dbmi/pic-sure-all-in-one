// Package tui is the unified PIC-SURE terminal app: an animated landing page,
// the dashboard, and a full-screen activity runner as sibling screens of one
// Bubble Tea program. All mutations still run the real bash scripts (via
// internal/actions); the TUI adds presentation only.
package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// defaultStarGlyph is the universally renderable sparkle for near stars.
const defaultStarGlyph = '✦'

// starGlyphs resolves the bright-star glyph set. PIC_SURE_STAR_GLYPHS is a
// comma-separated list of single-cell glyphs — e.g. Nerd Font icons for
// users whose terminal font carries them; the default stays a standard
// Unicode sparkle so evaluators without patched fonts never see tofu.
// Entries that aren't exactly one rune one cell wide are dropped so a
// misconfigured glyph can't shear the row layout.
func starGlyphs(getenv func(string) string) []rune {
	var out []rune
	for _, part := range strings.Split(getenv("PIC_SURE_STAR_GLYPHS"), ",") {
		part = strings.TrimSpace(part)
		r := []rune(part)
		if len(r) == 1 && lipgloss.Width(part) == 1 {
			out = append(out, r[0])
		}
	}
	if len(out) == 0 {
		return []rune{defaultStarGlyph}
	}
	return out
}

// AnimationsEnabled resolves the animation kill switch (spec: animations are
// starfield motion and logo shine — never colors or layout).
// Precedence: --no-animations flag > PIC_SURE_NO_ANIMATIONS env
// (1/true/yes disable; 0/false/no force-enable) > SSH_CONNECTION
// auto-disable > default on. NO_COLOR governs palette only and is handled by
// lipgloss, not here.
func AnimationsEnabled(noAnimFlag bool, getenv func(string) string) bool {
	if noAnimFlag {
		return false
	}
	switch getenv("PIC_SURE_NO_ANIMATIONS") {
	case "1", "true", "yes":
		return false
	case "0", "false", "no":
		return true
	}
	return getenv("SSH_CONNECTION") == ""
}
