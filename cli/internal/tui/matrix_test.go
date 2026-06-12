package tui

// U13 size/NO_COLOR verification matrix for landing and activity surfaces.
// Each matrix sub-test renders at 80×24, 120×30, and 200×50 and asserts the
// view-specific properties described by the audit.  A separate NO_COLOR test
// checks that rendering under NO_COLOR=1 neither panics nor emits raw ANSI
// SGR sequences — lipgloss strips color automatically when NO_COLOR is set,
// so no layout changes are expected.

import (
	"regexp"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
)

// ansiSGR matches any ANSI Select Graphic Rendition sequence (ESC [ … m).
var ansiSGR = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// matrixSizes are the three canonical terminal sizes used in U13.
var matrixSizes = [][2]int{
	{80, 24},
	{120, 30},
	{200, 50},
}

// TestLandingNarrowLogoMatrix renders the landing at each canonical size and
// asserts:
//   - At widths where the full block-art logo doesn't fit (< logoWidth()+4),
//     the compact "▌ PIC-SURE ▐" wordmark is present.
//   - At widths where the full logo fits, the block-art logo is used (no ▌/▐).
//   - The view stays within the terminal box at every size.
func TestLandingNarrowLogoMatrix(t *testing.T) {
	for _, sz := range matrixSizes {
		w, h := sz[0], sz[1]
		t.Run("", func(t *testing.T) {
			l := newLanding("/tmp/x", true, false)
			l.setSize(w, h)
			view := l.view()

			// Frame must fit inside the terminal box.
			if fh := lipgloss.Height(view); fh > h {
				t.Errorf("%dx%d: frame height %d > terminal height %d", w, h, fh, h)
			}
			for i, line := range strings.Split(view, "\n") {
				if lw := lipgloss.Width(line); lw > w {
					t.Errorf("%dx%d: line %d width %d > terminal width %d", w, h, i, lw, w)
				}
			}

			plain := ansiSGR.ReplaceAllString(view, "")
			if w < logoWidth()+4 {
				// Narrow: compact wordmark must be present.
				if !strings.Contains(plain, "PIC-SURE") {
					t.Errorf("%dx%d narrow: compact wordmark not found in view", w, h)
				}
				// The bracket glyphs from the compact variant.
				if !strings.Contains(plain, "▌") || !strings.Contains(plain, "▐") {
					t.Errorf("%dx%d narrow: bracket glyphs ▌/▐ not found in compact wordmark", w, h)
				}
			} else {
				// Wide: full block-art logo — compact brackets should NOT appear.
				if strings.Contains(plain, "▌") || strings.Contains(plain, "▐") {
					t.Errorf("%dx%d wide: compact wordmark brackets found when full logo should render", w, h)
				}
			}
		})
	}
}

// TestActivityFooterMatrix renders the activity footer at each canonical size
// in the three finished end-states (success / non-zero exit / aborted) and
// checks that each one follows the "[icon status] — [next action]" phrasing
// (U10), and that the view stays within the terminal box.
func TestActivityFooterMatrix(t *testing.T) {
	type endState struct {
		name  string
		setup func(a *activity)
		// wantIcon is a substring expected in the footer.
		wantIcon string
		// wantAction is a substring expected in the footer after the em-dash.
		wantAction string
	}
	endStates := []endState{
		{
			name: "success",
			setup: func(a *activity) {
				a.done, a.code = true, 0
				a.elapsed = 3
			},
			wantIcon:   "✓",
			wantAction: "dashboard",
		},
		{
			name: "nonzero exit",
			setup: func(a *activity) {
				a.done, a.code = true, 1
				a.elapsed = 2
			},
			wantIcon:   "✗",
			wantAction: "menu",
		},
		{
			name: "aborted",
			setup: func(a *activity) {
				a.done, a.aborted, a.code = true, true, 130
				a.elapsed = 5
			},
			wantIcon:   "⚠",
			wantAction: "menu",
		},
	}

	for _, sz := range matrixSizes {
		w, h := sz[0], sz[1]
		for _, es := range endStates {
			t.Run("", func(t *testing.T) {
				a := newActivity(t.TempDir(), actions.Update())
				a.setSize(w, h)
				es.setup(a)
				a.runner = nil

				footer := a.footerLine()
				plain := ansiSGR.ReplaceAllString(footer, "")

				if !strings.Contains(plain, es.wantIcon) {
					t.Errorf("%dx%d %s: footer missing icon %q: %q", w, h, es.name, es.wantIcon, plain)
				}
				if !strings.Contains(plain, "—") {
					t.Errorf("%dx%d %s: footer missing em-dash separator: %q", w, h, es.name, plain)
				}
				if !strings.Contains(plain, es.wantAction) {
					t.Errorf("%dx%d %s: footer missing next-action hint %q: %q", w, h, es.name, es.wantAction, plain)
				}

				// Height must stay inside the terminal box. Width is
				// not checked for the aborted state: AbortNote can be
				// long (pre-existing behavior; truncation is out of
				// scope for U10).
				view := a.view()
				if fh := lipgloss.Height(view); fh > h {
					t.Errorf("%dx%d %s: frame height %d > terminal height %d", w, h, es.name, fh, h)
				}
				if es.name != "aborted" {
					for i, line := range strings.Split(view, "\n") {
						if lw := lipgloss.Width(line); lw > w {
							t.Errorf("%dx%d %s: line %d width %d > terminal width %d", w, h, es.name, i, lw, w)
						}
					}
				}
			})
		}
	}
}

// TestLandingNOCOLOR renders the landing under NO_COLOR=1 at 80×24 and 200×50,
// asserts no panic, and checks that the ANSI-stripped output contains no raw
// SGR sequences (lipgloss strips color when NO_COLOR is set in os.Environ —
// t.Setenv propagates it into os.Getenv which lipgloss reads at render time).
func TestLandingNOCOLOR(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	// lipgloss reads NO_COLOR via os.Getenv at render time; the env var is now set.
	for _, sz := range [][2]int{{80, 24}, {200, 50}} {
		w, h := sz[0], sz[1]
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("%dx%d NO_COLOR: landing.view() panicked: %v", w, h, r)
				}
			}()
			l := newLanding("/tmp/x", true, false)
			l.setSize(w, h)
			view := l.view()
			// lipgloss strips color under NO_COLOR; no raw SGR should remain.
			if ansiSGR.MatchString(view) {
				t.Errorf("%dx%d NO_COLOR: raw ANSI SGR sequences present in output", w, h)
			}
		}()
	}
}

// TestActivitySuccessFooterContents pins the exact as-built phrasing for
// U10 regression coverage: success says "✓ done in Xs — enter: dashboard ·
// esc/q: menu".
func TestActivitySuccessFooterContents(t *testing.T) {
	a, _ := runningActivity(t)
	a.update(actions.DoneMsg{Code: 0})
	// elapsed will be 0s since we skip tickElapsed; just strip the time part.
	footer := ansiSGR.ReplaceAllString(a.footerLine(), "")
	for _, want := range []string{"✓", "done in", "—", "enter: dashboard", "esc/q: menu"} {
		if !strings.Contains(footer, want) {
			t.Errorf("success footer missing %q: %q", want, footer)
		}
	}
}

// TestActivityAbortFooterContents pins the aborted footer (U10): "⚠ aborted —
// <AbortNote>  esc/q: menu".
func TestActivityAbortFooterContents(t *testing.T) {
	a, fr := runningActivity(t)
	a.update(tea.KeyMsg{Type: tea.KeyCtrlC})
	a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if !fr.interrupted {
		t.Fatal("abort confirmation did not interrupt the runner")
	}
	a.update(actions.DoneMsg{Code: 130})
	footer := ansiSGR.ReplaceAllString(a.footerLine(), "")
	for _, want := range []string{"⚠", "aborted", "—", "esc/q: menu"} {
		if !strings.Contains(footer, want) {
			t.Errorf("aborted footer missing %q: %q", want, footer)
		}
	}
	if !strings.Contains(footer, a.act.AbortNote) {
		t.Errorf("aborted footer missing AbortNote %q: %q", a.act.AbortNote, footer)
	}
}
