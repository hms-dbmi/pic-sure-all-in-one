package styles

import (
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// TestPaletteValues pins the palette's color values so an accidental edit to a
// hex/ANSI code is caught. A render test asserting a title "carries the brand
// color" is brittle (lipgloss output depends on the terminal's detected
// background); asserting the declared values is the stable check.
func TestPaletteValues(t *testing.T) {
	if Brand.Light != "#224D96" || Brand.Dark != "#6F9EEF" {
		t.Errorf("Brand drifted from the logo hue: %+v", Brand)
	}
	// Status colors must stay on plain ANSI 1/2/3 so terminal themes remap them.
	for _, tc := range []struct {
		name string
		got  lipgloss.AdaptiveColor
		want string
	}{
		{"StatusOK", StatusOK, "2"},
		{"StatusWarn", StatusWarn, "3"},
		{"StatusBad", StatusBad, "1"},
	} {
		if tc.got.Light != tc.want || tc.got.Dark != tc.want {
			t.Errorf("%s = %+v, want ANSI %q on both backgrounds", tc.name, tc.got, tc.want)
		}
	}
}

// TestHelperStylesUsePalette verifies the helper styles are built from the
// palette colors (not redefined inline), checked via lipgloss's own accessors
// rather than rendered output.
func TestHelperStylesUsePalette(t *testing.T) {
	if fg, ok := Title.GetForeground().(lipgloss.AdaptiveColor); !ok || fg != Brand {
		t.Errorf("Title foreground = %v, want Brand %+v", Title.GetForeground(), Brand)
	}
	if !Title.GetBold() {
		t.Error("Title should be bold")
	}
	for _, tc := range []struct {
		name string
		got  lipgloss.Style
		want lipgloss.AdaptiveColor
	}{
		{"OK", OK, StatusOK},
		{"Warn", Warn, StatusWarn},
		{"Bad", Bad, StatusBad},
	} {
		fg, ok := tc.got.GetForeground().(lipgloss.AdaptiveColor)
		if !ok || fg != tc.want {
			t.Errorf("%s foreground = %v, want %+v", tc.name, tc.got.GetForeground(), tc.want)
		}
	}
}
