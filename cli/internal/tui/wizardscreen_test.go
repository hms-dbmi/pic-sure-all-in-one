package tui

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
)

// wizardRoot is a fixture checkout with a minimal .env.example (and
// optionally a .env for the reconfigure path).
func wizardRoot(t *testing.T, withEnv bool) string {
	t.Helper()
	dir := t.TempDir()
	example := "AUTH0_CLIENT_ID=\nAUTH0_CLIENT_SECRET=\nAUTH0_TENANT=avillachlab\nADMIN_EMAIL=\nHTTP_PORT=80\nHTTPS_PORT=443\nAUTH_MODE=required\nDB_MODE=local\nDB_HOST=\nDB_PORT=3306\nDB_ROOT_USER=root\nDB_ROOT_PASSWORD=\n"
	if err := os.WriteFile(filepath.Join(dir, ".env.example"), []byte(example), 0o644); err != nil {
		t.Fatal(err)
	}
	if withEnv {
		if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("ADMIN_EMAIL=current@example.com\nDB_MODE=local\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// drainForWritesDone pumps the cmd chain (following huh's intermediate
// nextField/nextGroup cmds and the U7 tea.Batch of write+tick) until it yields
// a wizardWritesDoneMsg, the write phase's terminal message. Batch messages are
// flattened so the write cmd inside the batch is found alongside the dot tick.
func drainForWritesDone(t *testing.T, s *wizardScreen, cmd tea.Cmd) *wizardWritesDoneMsg {
	t.Helper()
	queue := []tea.Cmd{cmd}
	for i := 0; i < 20 && len(queue) > 0; i++ {
		c := queue[0]
		queue = queue[1:]
		if c == nil {
			continue
		}
		switch msg := c().(type) {
		case wizardWritesDoneMsg:
			return &msg
		case tea.BatchMsg:
			for _, sub := range msg {
				queue = append(queue, sub)
			}
		case wizardWriteTickMsg:
			// The animation tick: don't follow it (it would loop forever) and
			// don't feed it back through update.
			continue
		default:
			_, next := s.update(msg)
			queue = append(queue, next)
		}
	}
	return nil
}

func TestWizardScreenSeedsFromExampleMergedWithEnv(t *testing.T) {
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.wf.Desired()["AUTH0_TENANT"]; got != "avillachlab" {
		t.Errorf("fresh setup seeds from .env.example; AUTH0_TENANT = %q", got)
	}

	s, err = newWizardScreen(wizardRoot(t, true), true)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.wf.Desired()["ADMIN_EMAIL"]; got != "current@example.com" {
		t.Errorf("reconfigure: .env override must win; ADMIN_EMAIL = %q", got)
	}
	// Sparse .env: keys it lacks fall back to example defaults, not empty.
	if got := s.wf.Desired()["AUTH0_TENANT"]; got != "avillachlab" {
		t.Errorf("reconfigure: missing keys seed from example; AUTH0_TENANT = %q", got)
	}
}

func TestWizardScreenReconfigureNeedsReadableEnv(t *testing.T) {
	if _, err := newWizardScreen(wizardRoot(t, false), true); err == nil {
		t.Fatal("reconfigure without .env must error")
	}
}

func TestWizardScreenAbortInMainCloses(t *testing.T) {
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	s.wf.Main.State = huh.StateAborted
	_, cmd := s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("abort produced no command")
	}
	msg, ok := cmd().(wizardClosedMsg)
	if !ok || !msg.aborted {
		t.Fatalf("got %#v, want wizardClosedMsg{aborted: true}", msg)
	}
}

func TestWizardScreenMainCompleteAdvancesToConfirm(t *testing.T) {
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	s.wf.Main.State = huh.StateCompleted
	_, _ = s.update(struct{}{}) // any pumped msg triggers the state check
	if s.phase != wizardConfirm || s.wf.Confirm == nil {
		t.Fatalf("phase = %v, want confirm phase with confirm form built", s.phase)
	}
}

func TestWizardScreenConfirmYesWritesThenRunsInit(t *testing.T) {
	root := wizardRoot(t, false)
	var wrote [][2]string
	origWrite := runWizardWrites
	runWizardWrites = func(r string, current, desired map[string]string) error {
		for k, v := range desired {
			if current[k] != v {
				wrote = append(wrote, [2]string{k, v})
			}
		}
		return nil
	}
	t.Cleanup(func() { runWizardWrites = origWrite })

	s, err := newWizardScreen(root, false)
	if err != nil {
		t.Fatal(err)
	}
	// Drive phase 1 to completion, deliver the confirm's Init msg like the
	// runtime would, then answer affirmatively: huh focuses the affirmative
	// button, so enter completes with true.
	s.wf.Main.State = huh.StateCompleted
	_, initCmd := s.update(struct{}{}) // advances to confirm; returns Confirm.Init()
	if initCmd != nil {
		_, _ = s.update(initCmd())
	}
	// huh focuses the affirmative button; pump KeyLeft to land on it before
	// enter. huh emits nextFieldMsg/nextGroupMsg as intermediate commands
	// before StateCompleted; drain the cmd chain until we receive a
	// wizardWritesDoneMsg or exhaust the pump.
	_, _ = s.update(tea.KeyMsg{Type: tea.KeyLeft})
	_, cmd := s.update(tea.KeyMsg{Type: tea.KeyEnter})
	done := drainForWritesDone(t, s, cmd)
	if done == nil {
		t.Fatal("confirm completion did not produce wizardWritesDoneMsg within 10 pumps")
	}
	if done.err != nil {
		t.Fatalf("writes failed: %v", done.err)
	}

	// Re-entrancy guard (the wizardWriting phase): a stray huh blink tick
	// arriving after the write was issued must not fire a second batch.
	if s.phase != wizardWriting {
		t.Fatalf("phase = %v, want wizardWriting after confirm", s.phase)
	}
	if _, again := s.update(struct{}{}); again != nil {
		t.Error("message during wizardWriting fired another command (double write/init)")
	}
}

// TestWizardWritingFeedback (U7): the write phase shows a key count and dots
// that grow across ticks, so a stall reads as work-in-progress, not a freeze.
func TestWizardWritingFeedback(t *testing.T) {
	s := &wizardScreen{phase: wizardWriting, writeKeys: 11}

	// Key count present, pluralized correctly.
	if got := s.writingLine(); !strings.Contains(got, "writing 11 config keys") {
		t.Errorf("writing line = %q, want the 11-key count", got)
	}
	s.writeKeys = 1
	if got := s.writingLine(); !strings.Contains(got, "writing 1 config key") || strings.Contains(got, "keys") {
		t.Errorf("singular key not handled: %q", got)
	}
	s.writeKeys = 11

	// Dots grow across ticks (trimming the fixed-width padding to compare).
	var seen []string
	for i := 0; i <= wizardWriteMaxDots+1; i++ {
		seen = append(seen, strings.TrimRight(s.writingLine(), " "))
		ns, cmd := s.update(wizardWriteTickMsg{})
		s = ns
		if cmd == nil {
			t.Fatal("write tick produced no follow-up tick (animation would stall)")
		}
	}
	// First few frames must have strictly growing dot runs (0,1,2,3), then wrap.
	dotCount := func(line string) int { return strings.Count(line, ".") }
	if dotCount(seen[0]) != 0 || dotCount(seen[1]) != 1 || dotCount(seen[2]) != 2 || dotCount(seen[3]) != 3 {
		t.Errorf("dots did not grow 0,1,2,3 across ticks: %q", seen)
	}
	if dotCount(seen[4]) != 0 {
		t.Errorf("dots did not reset after the max: %q", seen)
	}

	// The padded line keeps a constant width so the centered layout never jumps.
	w := -1
	s2 := &wizardScreen{phase: wizardWriting, writeKeys: 11}
	for i := 0; i <= wizardWriteMaxDots; i++ {
		if w < 0 {
			w = len(s2.writingLine())
		} else if len(s2.writingLine()) != w {
			t.Errorf("writing line width changes with dots (%d vs %d): %q", len(s2.writingLine()), w, s2.writingLine())
		}
		s2.writeDots = (s2.writeDots + 1) % (wizardWriteMaxDots + 1)
	}
}

func TestWizardScreenConfirmNoCloses(t *testing.T) {
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	s.wf.Main.State = huh.StateCompleted
	_, _ = s.update(struct{}{})
	// Abort at the confirm (esc) — must close as aborted, not write.
	s.wf.Confirm.State = huh.StateAborted
	_, cmd := s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("no command")
	}
	if msg, ok := cmd().(wizardClosedMsg); !ok || !msg.aborted {
		t.Fatalf("got %#v, want aborted close", msg)
	}
}

func TestWizardScreenViewRendersWithoutStarfield(t *testing.T) {
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	s.setSize(80, 24)
	if v := s.view(); strings.Contains(v, "⠀") || v == "" {
		t.Error("wizard view must render and must not contain starfield braille cells")
	}
}

// The footer says "esc cancel" — esc must actually cancel. huh disables its
// own esc binding, so the screen intercepts it before pumping the form.
func TestWizardScreenEscCancelsDirectly(t *testing.T) {
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	_, cmd := s.update(tea.KeyMsg{Type: tea.KeyEsc}) // no form-state fiddling
	if cmd == nil {
		t.Fatal("esc produced no command")
	}
	if msg, ok := cmd().(wizardClosedMsg); !ok || !msg.aborted {
		t.Fatalf("esc = %#v, want wizardClosedMsg{aborted: true}", msg)
	}
}

// dirtyWizard returns a screen with one field modified from its seed, driven
// through the real form like the runtime would (the pump path).
func dirtyWizard(t *testing.T) *wizardScreen {
	t.Helper()
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	s.setSize(100, 35)
	s = wizardPump(s, s.init(), 0)
	// IdP selector: choose "Skip" so the next visible group is admin email,
	// then type into it. Either edit makes the form dirty.
	s = wizardKey(s, tea.KeyMsg{Type: tea.KeyDown})
	s = wizardKey(s, tea.KeyMsg{Type: tea.KeyEnter})
	for _, r := range "James" {
		s = wizardKey(s, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	if !s.wf.Dirty() {
		t.Fatal("setup: form should be dirty after typing into a field")
	}
	return s
}

// TestWizardEscPristineClosesImmediately: an untouched form still discards on
// esc with no extra prompt (the cheap-exit path is preserved).
func TestWizardEscPristineClosesImmediately(t *testing.T) {
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	s.setSize(100, 35)
	s = wizardPump(s, s.init(), 0)

	s2, cmd := s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if s2.discarding {
		t.Fatal("pristine esc should not raise the discard confirm")
	}
	if cmd == nil {
		t.Fatal("pristine esc produced no command")
	}
	if msg, ok := cmd().(wizardClosedMsg); !ok || !msg.aborted {
		t.Fatalf("pristine esc = %#v, want wizardClosedMsg{aborted: true}", msg)
	}
}

// TestWizardEscDirtyAsksBeforeDiscarding: esc on a modified form raises the
// one-keystroke confirm instead of silently throwing the entered values away.
func TestWizardEscDirtyAsksBeforeDiscarding(t *testing.T) {
	s := dirtyWizard(t)

	s, cmd := s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if !s.discarding {
		t.Fatal("esc on a dirty form did not raise the discard confirm")
	}
	if cmd != nil {
		t.Fatal("esc on a dirty form must not close yet (no command)")
	}
	if !strings.Contains(wizardANSI.ReplaceAllString(s.view(), ""), "Discard setup?") {
		t.Errorf("footer missing the discard prompt:\n%s", s.view())
	}
}

// TestWizardDiscardConfirmYesCloses: y at the discard prompt closes as aborted.
func TestWizardDiscardConfirmYesCloses(t *testing.T) {
	s := dirtyWizard(t)
	s, _ = s.update(tea.KeyMsg{Type: tea.KeyEsc}) // raise the prompt

	_, cmd := s.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if cmd == nil {
		t.Fatal("y at the discard prompt produced no command")
	}
	if msg, ok := cmd().(wizardClosedMsg); !ok || !msg.aborted {
		t.Fatalf("y at the discard prompt = %#v, want wizardClosedMsg{aborted: true}", msg)
	}
}

// TestWizardDiscardConfirmNoStays: n (or esc) dismisses the prompt and keeps
// the form, entered values intact.
func TestWizardDiscardConfirmNoStays(t *testing.T) {
	s := dirtyWizard(t)
	s, _ = s.update(tea.KeyMsg{Type: tea.KeyEsc}) // raise the prompt

	s, cmd := s.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}})
	if cmd != nil {
		t.Fatal("n at the discard prompt should not close the wizard")
	}
	if s.discarding {
		t.Fatal("n did not dismiss the discard prompt")
	}
	if s.phase != wizardMain {
		t.Errorf("phase = %v, want wizardMain (form preserved)", s.phase)
	}
	if !s.wf.Dirty() {
		t.Error("entered values were lost after declining the discard")
	}

	// esc also dismisses the prompt (a second esc must not close).
	s, _ = s.update(tea.KeyMsg{Type: tea.KeyEsc}) // re-raise
	if !s.discarding {
		t.Fatal("esc did not re-raise the discard prompt")
	}
	s, cmd = s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if s.discarding || cmd != nil {
		t.Error("esc at the discard prompt should dismiss it, not close")
	}
}

var wizardANSI = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// wizardPump executes a cmd tree like the bubbletea runtime (batches
// included) and feeds the msgs back into the screen. Cmds that don't resolve
// within 50ms are timing ticks (cursor blink) — irrelevant to layout and
// discarded so the test doesn't serialize their sleeps.
func wizardPump(s *wizardScreen, cmd tea.Cmd, depth int) *wizardScreen {
	if cmd == nil || depth > 12 {
		return s
	}
	ch := make(chan tea.Msg, 1)
	go func() { ch <- cmd() }()
	var msg tea.Msg
	select {
	case msg = <-ch:
	case <-time.After(50 * time.Millisecond):
		return s
	}
	switch m := msg.(type) {
	case tea.BatchMsg:
		for _, c := range m {
			s = wizardPump(s, c, depth+1)
		}
		return s
	case nil:
		return s
	default:
		var next tea.Cmd
		s, next = s.update(msg)
		return wizardPump(s, next, depth+1)
	}
}

func wizardKey(s *wizardScreen, k tea.KeyMsg) *wizardScreen {
	s, cmd := s.update(k)
	return wizardPump(s, cmd, 0)
}

// Regression: typed text must be visible. huh recomputes group heights only
// in its WindowSizeMsg handler and only while no explicit WithWidth was set;
// calling WithWidth froze group viewports at their construction-time
// width-80 measurement, so at our narrower form width a wrapped description
// pushed the input line below the viewport fold — typing was recorded but
// invisible.
func TestWizardScreenTypedTextIsVisible(t *testing.T) {
	s, err := newWizardScreen(wizardRoot(t, false), false)
	if err != nil {
		t.Fatal(err)
	}
	s.setSize(100, 35) // as the app does before init
	s = wizardPump(s, s.init(), 0)

	// IdP selector: choose "Skip" so the next visible group is admin email.
	s = wizardKey(s, tea.KeyMsg{Type: tea.KeyDown})
	s = wizardKey(s, tea.KeyMsg{Type: tea.KeyEnter})

	for _, r := range "James" {
		s = wizardKey(s, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}

	view := wizardANSI.ReplaceAllString(s.view(), "")
	if !strings.Contains(view, "James") {
		t.Fatalf("typed text not visible in the rendered wizard:\n%s", view)
	}
}
