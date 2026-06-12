// Package styles holds the shared PIC-SURE TUI palette so the brand identity
// (the logo's blue) and the status semantics (ok/warn/bad) are defined once and
// reused across every screen. It deliberately depends on nothing in the project
// (only lipgloss) so BOTH the tui package and the dashboard package can import
// it without an import cycle — tui imports dashboard, so the palette cannot live
// in either of them.
//
// Colors are lipgloss.AdaptiveColor so they adapt to light/dark terminals, and
// they degrade automatically under NO_COLOR (lipgloss strips color when the
// environment requests it). The status colors keep the plain ANSI 1/2/3 values
// the dashboard and activity screens used before this package existed, so any
// terminal theme that remaps those slots still applies.
package styles

import "github.com/charmbracelet/lipgloss"

var (
	// Brand is the PIC-SURE logo hue (--color-primary-500,
	// oklch(43.14% 0.13 260.55)): exact #224D96 on light terminals; on dark
	// ones the same hue lifted to oklch 70% lightness (#6F9EEF) so it stays
	// legible over dark backgrounds. Matches the logo shine sweep.
	Brand = lipgloss.AdaptiveColor{Light: "#224D96", Dark: "#6F9EEF"}

	// StatusOK / StatusWarn / StatusBad are the semantic status colors, kept on
	// ANSI 2/3/1 (green/yellow/red) so terminal themes can remap them — the same
	// values the screens used as ad-hoc lipgloss.Color("2"/"3"/"1").
	StatusOK   = lipgloss.AdaptiveColor{Light: "2", Dark: "2"}
	StatusWarn = lipgloss.AdaptiveColor{Light: "3", Dark: "3"}
	StatusBad  = lipgloss.AdaptiveColor{Light: "1", Dark: "1"}
)

// Helper styles. Screens compose these (or .Foreground(Brand) etc.) rather than
// redefining the color slots inline.
var (
	// Title is a brand-colored bold style for screen titles and pane headers.
	Title = lipgloss.NewStyle().Bold(true).Foreground(Brand)

	// OK / Warn / Bad are the bare status foregrounds, matching the dashboard's
	// pre-existing okStyle/warnStyle/badStyle (no padding, no bold).
	OK   = lipgloss.NewStyle().Foreground(StatusOK)
	Warn = lipgloss.NewStyle().Foreground(StatusWarn)
	Bad  = lipgloss.NewStyle().Foreground(StatusBad)
)
