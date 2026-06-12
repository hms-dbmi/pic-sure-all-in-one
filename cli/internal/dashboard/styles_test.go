package dashboard

import (
	"testing"

	"github.com/charmbracelet/lipgloss"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/styles"
)

// TestDashboardUsesSharedPalette pins that the dashboard's status and title
// styles derive from the shared styles package (U6) rather than ad-hoc
// lipgloss.Color values. Asserted via style equality, not rendered output,
// which would be brittle across terminal backgrounds.
func TestDashboardUsesSharedPalette(t *testing.T) {
	for _, tc := range []struct {
		name string
		got  lipgloss.Style
		want lipgloss.AdaptiveColor
	}{
		{"okStyle", okStyle, styles.StatusOK},
		{"warnStyle", warnStyle, styles.StatusWarn},
		{"badStyle", badStyle, styles.StatusBad},
	} {
		fg, ok := tc.got.GetForeground().(lipgloss.AdaptiveColor)
		if !ok || fg != tc.want {
			t.Errorf("%s foreground = %v, want shared %+v", tc.name, tc.got.GetForeground(), tc.want)
		}
	}

	// Pane and screen titles carry the brand color.
	for _, tc := range []struct {
		name string
		got  lipgloss.Style
	}{
		{"titleStyle", titleStyle},
		{"paneTitle", paneTitle},
	} {
		fg, ok := tc.got.GetForeground().(lipgloss.AdaptiveColor)
		if !ok || fg != styles.Brand {
			t.Errorf("%s foreground = %v, want Brand %+v", tc.name, tc.got.GetForeground(), styles.Brand)
		}
	}
}
