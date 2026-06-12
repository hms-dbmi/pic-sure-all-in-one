package dashboard

// U13 size/color verification matrix for the dashboard help line (U12).
// Renders at 80×24, 120×30, and 200×50 in modeNormal and confirms:
//   - At <100 cols: the reduced hint set is shown.
//   - At ≥100 cols: the full legend is shown.
//   - In both cases: the view stays within the terminal box.
//
// Color emission is pinned around EXPLICIT lipgloss color profiles (see
// TestDashboardColorProfileSGR): in a test binary stdout is not a TTY, so
// lipgloss auto-detects the Ascii profile and emits zero SGR regardless of
// NO_COLOR — an env-var-based NO_COLOR assertion would be vacuous.

import (
	"fmt"
	"regexp"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// dashAnsiSGR matches any ANSI SGR escape sequence.
var dashAnsiSGR = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// dashMatrixSizes are the three canonical terminal sizes for U13.
var dashMatrixSizes = [][2]int{
	{80, 24},
	{120, 30},
	{200, 50},
}

// TestDashboardHelpLineMatrix renders the dashboard at each canonical size in
// modeNormal (the help-line mode that U12 targets) and asserts:
//   - At width <100: the reduced hint set ("↑/↓ select · r restart …") is used.
//   - At width ≥100: the full legend (containing "p/m/s", "X uninstall") is used.
//   - The view stays within the terminal box at every size.
func TestDashboardHelpLineMatrix(t *testing.T) {
	for _, sz := range dashMatrixSizes {
		w, h := sz[0], sz[1]
		t.Run(fmt.Sprintf("%dx%d", w, h), func(t *testing.T) {
			m := testModel(t)
			mm, _ := m.Update(tea.WindowSizeMsg{Width: w, Height: h})
			m = mm.(*model)
			// modeNormal is the default; the helpLine switch falls through to the
			// narrow/wide normal-mode branch.

			helpLine := ansi.Strip(m.helpLine())

			if w < 100 {
				// Narrow: reduced hint set.
				if !strings.Contains(helpLine, "↑/↓ select") {
					t.Errorf("%dx%d narrow: helpLine missing '↑/↓ select': %q", w, h, helpLine)
				}
				// The full legend's cryptic shorthands must NOT appear at narrow widths.
				if strings.Contains(helpLine, "p/m/s") {
					t.Errorf("%dx%d narrow: helpLine contains 'p/m/s' (full legend leaked): %q", w, h, helpLine)
				}
				if strings.Contains(helpLine, "X uninstall") {
					t.Errorf("%dx%d narrow: helpLine contains 'X uninstall' (full legend leaked): %q", w, h, helpLine)
				}
			} else {
				// Wide: full legend.
				if !strings.Contains(helpLine, "p/m/s") {
					t.Errorf("%dx%d wide: helpLine missing 'p/m/s': %q", w, h, helpLine)
				}
				if !strings.Contains(helpLine, "X uninstall") {
					t.Errorf("%dx%d wide: helpLine missing 'X uninstall': %q", w, h, helpLine)
				}
			}

			// Frame must fit inside the terminal box.
			view := m.View()
			if fh := lipgloss.Height(view); fh > h {
				t.Errorf("%dx%d: frame height %d > terminal height %d", w, h, fh, h)
			}
			for i, line := range strings.Split(view, "\n") {
				if lw := lipgloss.Width(line); lw > w {
					t.Errorf("%dx%d: line %d width %d > terminal width %d", w, h, i, lw, w)
				}
			}
		})
	}
}

// TestDashboardColorProfileSGR pins both sides of color emission around
// EXPLICIT lipgloss color profiles. A t.Setenv("NO_COLOR")-based test would be
// vacuous here: the test binary's stdout is not a TTY, so lipgloss's
// auto-detected profile is already Ascii (zero SGR no matter what), and the
// default renderer caches its detected profile via sync.Once anyway. Instead,
// lipgloss.SetColorProfile — the documented testing hook for exactly this —
// forces the default renderer (which the dashboard's package-level styles
// render through) to:
//   - termenv.TrueColor: the styled dashboard MUST emit SGR (proves the
//     styling is real, so the Ascii side below cannot pass trivially);
//   - termenv.Ascii (what lipgloss resolves NO_COLOR to): zero SGR, and
//     rendering must not panic.
//
// No test in this package uses t.Parallel, so mutating the default renderer's
// profile with a Cleanup restore is safe.
func TestDashboardColorProfileSGR(t *testing.T) {
	restore := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(restore) })

	for _, sz := range [][2]int{{80, 24}, {200, 50}} {
		w, h := sz[0], sz[1]

		// Color profile: styling must actually emit SGR.
		lipgloss.SetColorProfile(termenv.TrueColor)
		m := testModel(t)
		mm, _ := m.Update(tea.WindowSizeMsg{Width: w, Height: h})
		m = mm.(*model)
		if view := m.View(); !dashAnsiSGR.MatchString(view) {
			t.Errorf("%dx%d TrueColor: styled dashboard emitted no SGR (styling lost?)", w, h)
		}

		// Ascii profile (the NO_COLOR resolution): zero SGR.
		lipgloss.SetColorProfile(termenv.Ascii)
		m = testModel(t)
		mm, _ = m.Update(tea.WindowSizeMsg{Width: w, Height: h})
		m = mm.(*model)
		if view := m.View(); dashAnsiSGR.MatchString(view) {
			t.Errorf("%dx%d Ascii (NO_COLOR): raw ANSI SGR sequences present in output", w, h)
		}
	}
}
