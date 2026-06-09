package tui

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
)

type fakeRunner struct{ interrupted bool }

func (f *fakeRunner) WaitData() tea.Cmd     { return func() tea.Msg { return nil } }
func (f *fakeRunner) Resize(rows, cols int) {}
func (f *fakeRunner) Interrupt()            { f.interrupted = true }

func runningActivity(t *testing.T) (*activity, *fakeRunner) {
	t.Helper()
	a := newActivity(t.TempDir(), actions.Update())
	a.setSize(80, 24)
	fr := &fakeRunner{}
	a.runner = fr
	return a, fr
}

func TestActivityEscWhileRunningAsksForConfirmation(t *testing.T) {
	a, fr := runningActivity(t)
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyEsc})
	if !a.confirmingAbort {
		t.Fatal("esc while running did not enter abort confirmation")
	}
	if fr.interrupted {
		t.Fatal("esc interrupted immediately; must confirm first")
	}
	// n dismisses
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}})
	if a.confirmingAbort {
		t.Fatal("'n' did not dismiss the abort confirmation")
	}
}

func TestActivityConfirmedAbortInterruptsAndShowsNote(t *testing.T) {
	a, fr := runningActivity(t)
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyCtrlC})
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if !fr.interrupted {
		t.Fatal("'y' did not interrupt the runner")
	}
	if !a.aborted {
		t.Fatal("aborted flag not set")
	}
	// Child exits after the interrupt.
	_, _ = a.update(actions.DoneMsg{Code: 130})
	view := a.view()
	if !strings.Contains(view, a.act.AbortNote) {
		t.Errorf("post-abort view missing AbortNote %q", a.act.AbortNote)
	}
}

func TestActivityAbortRaceWithCompletion(t *testing.T) {
	a, fr := runningActivity(t)
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyEsc}) // user is being asked "abort?"
	_, _ = a.update(actions.DoneMsg{Code: 0})     // ...and the run completes meanwhile
	if a.confirmingAbort {
		t.Fatal("DoneMsg did not dismiss the pending abort confirmation")
	}
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if a.aborted || fr.interrupted {
		t.Fatal("'y' after completion must not abort the finished run")
	}
	if !strings.Contains(a.view(), "enter: open dashboard") {
		t.Error("success footer lost after the abort/completion race")
	}
}

func TestActivityOutputSanitizedAndVisible(t *testing.T) {
	a, _ := runningActivity(t)
	// CRLF newlines, \r progress rewrites, and non-SGR escapes are PTY
	// reality; the screen must show clean text (raw control sequences would
	// move the real cursor and shear the frame).
	_, _ = a.update(actions.OutputMsg{Data: []byte("hello\r\nclone:  1%\rclone: 100%\r\n\x1b[2Kerased\r\n")})
	got := a.out.String()
	if got != "hello\nclone: 100%\nerased" {
		t.Fatalf("sanitized output = %q", got)
	}
	if !strings.Contains(a.vp.View(), "hello") {
		t.Error("viewport missing sanitized output")
	}
}

func TestActivitySuccessEnterOpensDashboard(t *testing.T) {
	a, _ := runningActivity(t)
	_, _ = a.update(actions.DoneMsg{Code: 0})
	if !strings.Contains(a.view(), "enter: open dashboard") {
		t.Error("success footer missing dashboard hint")
	}
	_, cmd := a.update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("enter after success returned no command")
	}
	msg, ok := cmd().(activityClosedMsg)
	if !ok || !msg.openDashboard {
		t.Fatalf("enter after success = %#v, want activityClosedMsg{openDashboard: true}", msg)
	}
}

func TestActivityFailureEscReturnsToMenu(t *testing.T) {
	a, _ := runningActivity(t)
	_, _ = a.update(actions.DoneMsg{Code: 3})
	if !strings.Contains(a.view(), "exited 3") {
		t.Error("failure footer missing exit code")
	}
	_, cmd := a.update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("esc after failure returned no command")
	}
	if msg, ok := cmd().(activityClosedMsg); !ok || msg.openDashboard {
		t.Fatalf("esc after failure = %#v, want activityClosedMsg{openDashboard: false}", msg)
	}
	// enter after failure must NOT open the dashboard
	a2, _ := runningActivity(t)
	_, _ = a2.update(actions.DoneMsg{Code: 3})
	if _, cmd := a2.update(tea.KeyMsg{Type: tea.KeyEnter}); cmd != nil {
		t.Error("enter after failure should be inert")
	}
}

func TestActivityDoubleCtrlCAborts(t *testing.T) {
	a, fr := runningActivity(t)
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyCtrlC}) // ask
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyCtrlC}) // reflexive second press = yes
	if !fr.interrupted || !a.aborted {
		t.Fatal("second ctrl+c did not confirm the abort")
	}
}

func TestActivityFrameStaysInBox(t *testing.T) {
	a, _ := runningActivity(t)
	var b strings.Builder
	for i := 0; i < 300; i++ {
		fmt.Fprintf(&b, "layer%03d: %s\r\n", i, strings.Repeat("0123456789abcdef ", 12))
	}
	_, _ = a.update(actions.OutputMsg{Data: []byte(b.String())})
	view := a.view()
	if h := lipgloss.Height(view); h > 24 {
		t.Errorf("activity frame height %d exceeds 24", h)
	}
	for i, line := range strings.Split(view, "\n") {
		if w := lipgloss.Width(line); w > 80 {
			t.Errorf("line %d width %d exceeds 80", i, w)
		}
	}
}
