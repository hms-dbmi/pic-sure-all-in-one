package dashboard

import (
	"fmt"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/contract"
)

// fakeRunner stands in for *actions.PTYRunner so abort/escalation tests can
// observe Interrupt/Kill without spawning a real PTY (mirrors the tui pkg).
type fakeRunner struct {
	interrupted bool
	killed      bool
}

func (f *fakeRunner) WaitData() tea.Cmd     { return func() tea.Msg { return nil } }
func (f *fakeRunner) Resize(rows, cols int) {}
func (f *fakeRunner) Interrupt()            { f.interrupted = true }
func (f *fakeRunner) Kill()                 { f.killed = true }

// actingModel returns a sized model parked in modeActing with a live fake
// runner, as if an action had just been dispatched.
func actingModel(t *testing.T) (*model, *fakeRunner) {
	t.Helper()
	m := testModel(t)
	fr := &fakeRunner{}
	m.mode = modeActing
	m.runner = fr
	m.actionName = "update"
	m.actionAbortNote = actions.Update().AbortNote
	m.actionOut = actions.NewOutputBuffer()
	return m, fr
}

func keyMsg(s string) tea.KeyMsg {
	switch s {
	case "esc":
		return tea.KeyMsg(tea.Key{Type: tea.KeyEsc})
	case "ctrl+c":
		return tea.KeyMsg(tea.Key{Type: tea.KeyCtrlC})
	case "up":
		return tea.KeyMsg(tea.Key{Type: tea.KeyUp})
	case "down":
		return tea.KeyMsg(tea.Key{Type: tea.KeyDown})
	case "home":
		return tea.KeyMsg(tea.Key{Type: tea.KeyHome})
	case "pgup":
		return tea.KeyMsg(tea.Key{Type: tea.KeyPgUp})
	default:
		return tea.KeyMsg(tea.Key{Type: tea.KeyRunes, Runes: []rune(s)})
	}
}

// testModel returns a sized model rooted in a temp dir (any spawned helper
// process fails fast and harmlessly there).
func testModel(t *testing.T) *model {
	t.Helper()
	m := newModel(t.TempDir())
	m.width, m.height = 120, 40
	m.layout()
	return m
}

func update(t *testing.T, m *model, msg tea.Msg) (*model, tea.Cmd) {
	t.Helper()
	next, cmd := m.Update(msg)
	nm, ok := next.(*model)
	if !ok {
		t.Fatalf("Update returned %T, want *model", next)
	}
	return nm, cmd
}

func TestActionKeysOpenConfirm(t *testing.T) {
	// p (read-only) and R (combined reset dialog) deliberately do NOT open a
	// plain confirm — they have their own tests below.
	tests := []struct {
		key         string
		wantName    string
		destructive bool
	}{
		{"u", "update", false},
		{"m", "migrate", false},
		{"s", "seed-db", false},
		{"X", "uninstall", true},
	}
	for _, tt := range tests {
		t.Run(tt.key, func(t *testing.T) {
			m := testModel(t)
			m, _ = update(t, m, keyMsg(tt.key))
			if m.mode != modeConfirm {
				t.Fatalf("mode = %v, want modeConfirm", m.mode)
			}
			if m.pending == nil || m.pending.Name != tt.wantName {
				t.Fatalf("pending = %+v, want %s", m.pending, tt.wantName)
			}
			if m.pending.Destructive != tt.destructive {
				t.Errorf("destructive = %v, want %v", m.pending.Destructive, tt.destructive)
			}
			if m.form == nil {
				t.Error("confirm form not created")
			}
		})
	}
}

func TestPickerKeyOpensPicker(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("e"))
	if m.mode != modePick {
		t.Fatalf("mode = %v, want modePick", m.mode)
	}
}

// reapRunner interrupts and reaps a runner a dispatch may have spawned so the
// test does not leak a short-lived bash child (the script is missing in the
// temp root, so it exits immediately, but reap it deterministically anyway).
func reapRunner(m *model) {
	if m.runner != nil {
		m.runner.Interrupt()
		m.runner = nil
	}
}

// TestPreflightDispatchesImmediately: p is read-only, so the dashboard runs it
// at once (no confirm) — mirroring the landing's Preflight-check entry.
func TestPreflightDispatchesImmediately(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("p"))
	defer reapRunner(m)
	if m.mode != modeActing {
		t.Fatalf("mode = %v, want modeActing (p should dispatch without a confirm)", m.mode)
	}
	if m.actionName != "preflight" {
		t.Errorf("actionName = %q, want preflight", m.actionName)
	}
}

// TestDemoPickerDispatchesWithoutConfirm: the picker IS the consent, so a
// dataset selection dispatches the demo-data action directly — no second
// confirm dialog (spec consent model).
func TestDemoPickerDispatchesWithoutConfirm(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("e"))
	if m.mode != modePick {
		t.Fatalf("e did not open the picker: mode=%v", m.mode)
	}
	m.pickedDataset = "synthea"
	m.form.State = huh.StateCompleted

	m, _ = update(t, m, struct{}{}) // any msg drives the completed form
	defer reapRunner(m)
	if m.mode != modeActing {
		t.Fatalf("mode = %v, want modeActing (picker should dispatch, not confirm)", m.mode)
	}
	if m.actionName != "demo-data synthea" {
		t.Errorf("actionName = %q, want demo-data synthea", m.actionName)
	}

	// Cancel (empty selection) must NOT dispatch.
	m = testModel(t)
	m, _ = update(t, m, keyMsg("e"))
	m.pickedDataset = ""
	m.form.State = huh.StateCompleted
	m, _ = update(t, m, struct{}{})
	if m.mode != modeNormal || m.runner != nil {
		t.Errorf("Cancel selection dispatched: mode=%v runner=%v", m.mode, m.runner)
	}
}

// TestDashboardResetCombinedDialog mirrors TestLandingResetCombinedScreen: R
// opens ONE dialog (scope keep/all + repos toggle + typed word); each toggle
// combo dispatches reset.sh with the right variant, and a wrong word never
// dispatches. ResetWith's exact args are pinned in actions_test.go; here the
// actionName uniquely identifies the dispatched variant.
func TestDashboardResetCombinedDialog(t *testing.T) {
	openReset := func(t *testing.T) *model {
		t.Helper()
		m := testModel(t)
		m, _ = update(t, m, keyMsg("R"))
		if m.mode != modeReset || m.form == nil {
			t.Fatal("R did not open the combined reset dialog")
		}
		if m.resetScope != "keep" || m.resetRepos {
			t.Fatalf("defaults = scope %q repos %v, want keep/false", m.resetScope, m.resetRepos)
		}
		return m
	}

	cases := []struct {
		name           string
		scope          string
		repos          bool
		wantActionName string
	}{
		{"keep", "keep", false, "reset"},
		{"full wipe", "all", false, "reset --all"},
		{"keep+repos", "keep", true, "reset --repos"},
		{"all+repos", "all", true, "reset --all --repos"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := openReset(t)
			m.resetScope, m.resetRepos, m.confirmText = c.scope, c.repos, "reset"
			m.form.State = huh.StateCompleted

			m, _ = update(t, m, struct{}{})
			defer reapRunner(m)
			if m.mode != modeActing {
				t.Fatalf("mode = %v, want modeActing (reset should dispatch)", m.mode)
			}
			if m.actionName != c.wantActionName {
				t.Errorf("actionName = %q, want %q", m.actionName, c.wantActionName)
			}
		})
	}

	// Wrong word must not dispatch even if the form is forced complete.
	t.Run("wrong word", func(t *testing.T) {
		m := openReset(t)
		m.resetScope, m.resetRepos, m.confirmText = "all", true, "nope"
		m.form.State = huh.StateCompleted
		m, _ = update(t, m, struct{}{})
		defer reapRunner(m)
		if m.mode != modeNormal || m.runner != nil {
			t.Errorf("wrong word dispatched: mode=%v runner=%v", m.mode, m.runner)
		}
	})
}

// TestDashboardResetDialogRendersAllParts: the scope select, repo toggle, and
// typed-word confirm all render on the one reset screen (matching the landing).
func TestDashboardResetDialogRendersAllParts(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("R"))
	if m.form == nil || m.mode != modeReset {
		t.Fatal("R did not open the combined reset dialog")
	}
	view := ansi.Strip(m.View())
	for _, want := range []string{"Keep the database", "Full wipe", "reset sibling repos to release refs", `Type "reset"`} {
		if !strings.Contains(view, want) {
			t.Errorf("reset dialog missing %q", want)
		}
	}
}

func TestRestartRequiresSelectedService(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("r"))
	if m.mode != modeNormal {
		t.Fatal("restart with no services should be a no-op")
	}

	m.services = []contract.ComposeService{{Service: "wildfly"}, {Service: "hpds"}}
	m.selected = 1
	m, _ = update(t, m, keyMsg("r"))
	if m.mode != modeConfirm || m.pending == nil || m.pending.Name != "restart hpds" {
		t.Fatalf("pending = %+v, want restart hpds", m.pending)
	}
}

func TestQuitKeyQuits(t *testing.T) {
	m := testModel(t)
	_, cmd := update(t, m, keyMsg("q"))
	if cmd == nil {
		t.Fatal("q should produce a command")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("q should quit")
	}
}

func TestServicesMsgClampsSelection(t *testing.T) {
	m := testModel(t)
	m.services = []contract.ComposeService{{Service: "a"}, {Service: "b"}, {Service: "c"}}
	m.selected = 2
	m.logSvc = "c" // suppress initial follower spawn

	m, _ = update(t, m, servicesMsg{services: []contract.ComposeService{{Service: "a"}}})
	if m.selected != 0 {
		t.Errorf("selected = %d, want 0 after shrink", m.selected)
	}
}

func TestStaleLogLinesAreDiscarded(t *testing.T) {
	m := testModel(t)
	m.logSession = &logSession{id: 5, cancel: func() {}, lines: make(chan string)}
	m.logSvc = "wildfly"

	m, _ = update(t, m, logLinesMsg{sessionID: 4, lines: []string{"stale line"}})
	if len(m.logLines) != 0 {
		t.Errorf("stale session line was appended: %v", m.logLines)
	}
}

func TestLogLinesCapped(t *testing.T) {
	m := testModel(t)
	ch := make(chan string, 1)
	ch <- "next" // keep waitLines from blocking when the returned cmd runs
	m.logSession = &logSession{id: 1, cancel: func() {}, lines: ch}
	m.logLines = make([]string, maxLogLines)

	m, _ = update(t, m, logLinesMsg{sessionID: 1, lines: []string{"overflow-1", "overflow-2"}})
	if len(m.logLines) != maxLogLines {
		t.Errorf("log lines = %d, want capped at %d", len(m.logLines), maxLogLines)
	}
	if m.logLines[len(m.logLines)-1] != "overflow-2" {
		t.Error("newest line should be kept")
	}
}

func TestWaitLinesBatchesBufferedLines(t *testing.T) {
	ch := make(chan string, 8)
	for _, l := range []string{"a", "b", "c"} {
		ch <- l
	}
	s := &logSession{id: 1, cancel: func() {}, lines: ch}

	msg := s.waitLines()()
	batch, ok := msg.(logLinesMsg)
	if !ok {
		t.Fatalf("got %T, want logLinesMsg", msg)
	}
	if len(batch.lines) != 3 || batch.lines[0] != "a" || batch.lines[2] != "c" {
		t.Errorf("batch = %v, want [a b c] in one message", batch.lines)
	}
}

func TestActionDoneFormatsResultAndRefreshes(t *testing.T) {
	tests := []struct {
		name string
		msg  actions.DoneMsg
		want string
	}{
		{"success", actions.DoneMsg{Code: 0}, "update succeeded (exit 0)"},
		{"failure", actions.DoneMsg{Code: 137}, "update FAILED (exit 137)"},
		{"signal death uses 128+N convention", actions.DoneMsg{Code: 130}, "update FAILED (exit 130)"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := testModel(t)
			m.mode = modeActing
			m.actionName = "update"
			m.runner = &actions.PTYRunner{}

			m, cmd := update(t, m, tt.msg)
			if m.lastResult != tt.want {
				t.Errorf("lastResult = %q, want %q", m.lastResult, tt.want)
			}
			if m.runner != nil {
				t.Error("runner should be cleared")
			}
			if m.mode != modeActing {
				t.Error("pane should stay open until dismissed")
			}
			if cmd == nil {
				t.Error("completion should trigger a services+status refresh")
			}
		})
	}
}

func TestEscClosesFinishedActionPane(t *testing.T) {
	m := testModel(t)
	m.mode = modeActing
	m.runner = nil // finished
	m.actionOut = actions.NewOutputBuffer()

	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeNormal {
		t.Errorf("mode = %v, want modeNormal after esc on finished pane", m.mode)
	}

	// While still running, esc must NOT close the pane.
	m.mode = modeActing
	m.runner = &actions.PTYRunner{}
	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeActing {
		t.Error("esc must not close a pane with a live runner")
	}
}

// TestDashboardAbortConfirmThenInterrupt: a bare ctrl+c on a live pane action
// must NOT interrupt immediately — it asks to confirm first (parity with the
// activity screen); y then interrupts and starts the grace timer.
func TestDashboardAbortConfirmThenInterrupt(t *testing.T) {
	m, fr := actingModel(t)

	m, _ = update(t, m, keyMsg("ctrl+c"))
	if !m.confirmingAbort {
		t.Fatal("ctrl+c did not enter abort confirmation")
	}
	if fr.interrupted {
		t.Fatal("ctrl+c interrupted immediately; must confirm first")
	}
	if !strings.Contains(ansi.Strip(m.View()), "abort it? (y/n)") {
		t.Errorf("pane footer missing the abort confirm prompt:\n%s", ansi.Strip(m.View()))
	}

	m, cmd := update(t, m, keyMsg("y"))
	if !fr.interrupted || !m.aborted {
		t.Fatal("y did not interrupt / set aborted")
	}
	if cmd == nil {
		t.Fatal("confirmed abort did not start the grace timer")
	}
	if !strings.Contains(ansi.Strip(m.View()), "aborting") {
		t.Errorf("pane footer does not report the aborting state:\n%s", ansi.Strip(m.View()))
	}
}

// TestDashboardAbortConfirmDismiss: n keeps the run going (no interrupt).
func TestDashboardAbortConfirmDismiss(t *testing.T) {
	m, fr := actingModel(t)
	m, _ = update(t, m, keyMsg("esc")) // esc also asks (parity with activity)
	if !m.confirmingAbort {
		t.Fatal("esc on a live pane did not ask to confirm")
	}
	m, _ = update(t, m, keyMsg("n"))
	if m.confirmingAbort {
		t.Fatal("n did not dismiss the abort confirmation")
	}
	if fr.interrupted {
		t.Fatal("n must not interrupt the run")
	}
	if m.mode != modeActing {
		t.Errorf("mode = %v, want modeActing (run continues)", m.mode)
	}
}

// TestDashboardAbortShowsNote: after a confirmed abort and the child's exit,
// the finished pane shows the action's AbortNote (it never did before).
func TestDashboardAbortShowsNote(t *testing.T) {
	m, _ := actingModel(t)
	m, _ = update(t, m, keyMsg("ctrl+c"))
	m, _ = update(t, m, keyMsg("y"))

	// Child exits after the interrupt.
	m, _ = update(t, m, actions.DoneMsg{Code: 130})
	view := ansi.Strip(m.View())
	if !strings.Contains(view, m.actionAbortNote) {
		t.Errorf("post-abort pane missing AbortNote %q:\n%s", m.actionAbortNote, view)
	}
	if !strings.Contains(view, "aborted") {
		t.Errorf("post-abort pane does not say aborted:\n%s", view)
	}
}

// TestDashboardKillEscalation: the grace tick with a live child offers K, and
// K force-kills; a DoneMsg cancels a pending offer.
func TestDashboardKillEscalation(t *testing.T) {
	m, fr := actingModel(t)
	m, _ = update(t, m, keyMsg("ctrl+c"))
	m, _ = update(t, m, keyMsg("y"))

	// K is inert before the offer is live.
	m, _ = update(t, m, keyMsg("K"))
	if fr.killed {
		t.Fatal("K killed before the grace period elapsed")
	}

	// Grace elapses with the child still alive → offer K.
	m, _ = update(t, m, killGraceMsg{seq: m.actionSeq})
	if !m.killOffered {
		t.Fatal("grace elapsing with a live child did not offer the force-kill")
	}
	if !strings.Contains(ansi.Strip(m.View()), "force kill") {
		t.Errorf("pane footer missing the force-kill offer:\n%s", ansi.Strip(m.View()))
	}

	_, _ = update(t, m, keyMsg("K"))
	if !fr.killed {
		t.Fatal("K did not force-kill the child")
	}
}

// TestDashboardDoneCancelsKillOffer: a child that exits on its own clears any
// pending kill offer, and a late grace tick is a no-op.
func TestDashboardDoneCancelsKillOffer(t *testing.T) {
	m, _ := actingModel(t)
	m, _ = update(t, m, keyMsg("ctrl+c"))
	m, _ = update(t, m, keyMsg("y"))

	m, _ = update(t, m, actions.DoneMsg{Code: 130})
	if m.killOffered {
		t.Fatal("kill offer set after the child already exited")
	}
	if m.aborted {
		t.Fatal("live aborted flag not reset by DoneMsg (belt-and-braces guard)")
	}
	m, _ = update(t, m, killGraceMsg{seq: m.actionSeq})
	if m.killOffered {
		t.Fatal("late grace tick offered the kill on a finished run")
	}
}

// TestDashboardStaleGraceTimerIgnored: a grace timer armed by aborting run A
// keeps ticking in the runtime after A exits and the pane closes. When it
// fires during a later aborted run B it must be discarded (seq mismatch) —
// otherwise B's 10s grace would be cut short and the force-kill offered
// prematurely. B's own timer, at its proper time, still escalates.
func TestDashboardStaleGraceTimerIgnored(t *testing.T) {
	origStart := startPTY
	startPTY = func(root string, act actions.Action, rows, cols int) (runnerHandle, error) {
		return &fakeRunner{}, nil
	}
	t.Cleanup(func() { startPTY = origStart })

	m := testModel(t)

	// Run A: dispatch, abort (arms A's timer), child exits, pane closed.
	mm, _ := m.startAction(actions.Update())
	m = mm.(*model)
	seqA := m.actionSeq
	m, _ = update(t, m, keyMsg("ctrl+c"))
	m, _ = update(t, m, keyMsg("y"))
	m, _ = update(t, m, actions.DoneMsg{Code: 130})
	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeNormal {
		t.Fatalf("mode = %v, want modeNormal after closing run A's pane", m.mode)
	}

	// Run B: dispatch and abort — B's own grace window starts now.
	mm, _ = m.startAction(actions.Migrate())
	m = mm.(*model)
	seqB := m.actionSeq
	if seqB == seqA {
		t.Fatal("startAction did not bump actionSeq between runs")
	}
	m, _ = update(t, m, keyMsg("ctrl+c"))
	m, _ = update(t, m, keyMsg("y"))

	// Run A's stale timer fires mid-grace for B: must be discarded.
	m, _ = update(t, m, killGraceMsg{seq: seqA})
	if m.killOffered {
		t.Fatal("stale grace timer from run A set killOffered during run B")
	}

	// B's own timer at its proper time still escalates.
	m, _ = update(t, m, killGraceMsg{seq: seqB})
	if !m.killOffered {
		t.Fatal("run B's own grace timer did not offer the force-kill")
	}
}

// TestDashboardCtrlCOnFinishedPaneQuits: ctrl+c on a finished pane quits (the
// child has exited), matching q in normal mode; esc still just closes the pane.
func TestDashboardCtrlCOnFinishedPaneQuits(t *testing.T) {
	m, _ := actingModel(t)
	m.runner = nil // finished

	_, cmd := update(t, m, keyMsg("ctrl+c"))
	if cmd == nil {
		t.Fatal("ctrl+c on a finished pane returned no command")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatalf("ctrl+c on a finished pane = %T, want tea.QuitMsg", cmd())
	}
}

func TestPtyOutputSanitizedIntoPane(t *testing.T) {
	m := testModel(t)
	m.mode = modeActing
	m.actionOut = actions.NewOutputBuffer()

	// Progress rewrites collapse; CRLF splits lines (PTY semantics).
	m, _ = update(t, m, actions.OutputMsg{Data: []byte("pull:  10%\rpull: 100%\r\ndone\r\n")})
	if got := m.actionOut.String(); got != "pull: 100%\ndone" {
		t.Errorf("sanitized output = %q", got)
	}
}

func TestSelectionMovesAndClamps(t *testing.T) {
	m := testModel(t)
	m.services = []contract.ComposeService{{Service: "a"}, {Service: "b"}}
	m.logSvc = "a" // pretend a follower exists so moves only switch sessions

	m, _ = update(t, m, keyMsg("down"))
	if m.selected != 1 {
		t.Errorf("selected = %d, want 1", m.selected)
	}
	m, _ = update(t, m, keyMsg("down"))
	if m.selected != 1 {
		t.Errorf("selected = %d, want clamped at 1", m.selected)
	}
	m, _ = update(t, m, keyMsg("up"))
	m, _ = update(t, m, keyMsg("up"))
	if m.selected != 0 {
		t.Errorf("selected = %d, want clamped at 0", m.selected)
	}
}

func TestEscInNormalModeEmitsBackMsg(t *testing.T) {
	m := newModel(t.TempDir())
	_, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("esc in normal mode returned no command")
	}
	if _, ok := cmd().(BackMsg); !ok {
		t.Fatalf("esc in normal mode = %T, want BackMsg", cmd())
	}
}

// TestNextLogRetryDelay pins the backoff schedule: start at the base, double up
// to the cap, then stay capped (a pure function so the schedule is asserted
// without sleeping).
func TestNextLogRetryDelay(t *testing.T) {
	got := []time.Duration{}
	d := time.Duration(0)
	for i := 0; i < 6; i++ {
		d = nextLogRetryDelay(d)
		got = append(got, d)
	}
	want := []time.Duration{2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("delay[%d] = %v, want %v (full schedule %v)", i, got[i], want[i], got)
		}
	}
}

// TestLogClosedBacksOffAndKeepsScrollback verifies bug-fix #2: a follower that
// keeps dying no longer wipes the pane and re-renders the error every 2s.
// Instead logClosedMsg preserves the existing scrollback + last error line and
// schedules a restart after a delay that grows on each consecutive failure.
func TestLogClosedBacksOffAndKeepsScrollback(t *testing.T) {
	m := testModel(t)
	m.logSvc = "wildfly"
	// Existing scrollback incl. a follower error line (as startLogSession's
	// failed-stub would have appended before closing).
	m.logLines = []string{"wildfly | booting", "[log follower] start failed: boom"}
	before := append([]string(nil), m.logLines...)
	m.logSession = &logSession{id: m.logSeq, cancel: func() {}, lines: make(chan string)}

	// First closure: schedules a restart at the base delay, scrollback intact.
	m, cmd := update(t, m, logClosedMsg{sessionID: m.logSeq})
	if m.logSession != nil {
		t.Fatal("logClosedMsg did not drop the dead session")
	}
	if !equalStrings(m.logLines, before) {
		t.Errorf("scrollback was wiped on retry: got %v, want %v", m.logLines, before)
	}
	if m.logRetryDelay != logRetryBase {
		t.Errorf("first backoff = %v, want %v", m.logRetryDelay, logRetryBase)
	}
	// A restart is scheduled (a tea.Tick — not executed here: it would sleep for
	// the delay. The delay is asserted via m.logRetryDelay above and below).
	if cmd == nil {
		t.Fatal("logClosedMsg did not schedule a restart")
	}

	// A second consecutive failure (no successful lines in between) grows the
	// delay — the retry schedule backs off rather than hammering every 2s.
	prevDelay := m.logRetryDelay
	m.logSession = &logSession{id: m.logSeq, cancel: func() {}, lines: make(chan string)}
	m, _ = update(t, m, logClosedMsg{sessionID: m.logSeq})
	if m.logRetryDelay <= prevDelay {
		t.Errorf("second backoff %v did not grow past the first %v", m.logRetryDelay, prevDelay)
	}
	if !equalStrings(m.logLines, before) {
		t.Errorf("scrollback wiped on second retry: got %v", m.logLines)
	}
}

// TestLogLinesResetBackoff verifies the backoff resets once a real (non-stub)
// session delivers lines, so a later transient drop retries quickly again.
func TestLogLinesResetBackoff(t *testing.T) {
	m := testModel(t)
	m.logSvc = "wildfly"
	m.logRetryDelay = 16 * time.Second // as if several failures had accrued
	ch := make(chan string, 1)
	ch <- "next" // keep waitLines from blocking when the returned cmd runs
	m.logSession = &logSession{id: 7, cancel: func() {}, lines: ch} // failed=false: real session

	m, _ = update(t, m, logLinesMsg{sessionID: 7, lines: []string{"wildfly | up"}})
	if m.logRetryDelay != 0 {
		t.Errorf("real lines did not reset the backoff: logRetryDelay = %v, want 0", m.logRetryDelay)
	}

	// A failed-stub session delivering its single error line must NOT reset it.
	m.logRetryDelay = 16 * time.Second
	m.logSession = &logSession{id: 8, cancel: func() {}, lines: make(chan string), failed: true}
	m, _ = update(t, m, logLinesMsg{sessionID: 8, lines: []string{"[log follower] start failed: boom"}})
	if m.logRetryDelay != 16*time.Second {
		t.Errorf("failed-stub line reset the backoff: logRetryDelay = %v, want unchanged 16s", m.logRetryDelay)
	}
}

// TestLogRetryMsgSeqGuard verifies the scheduled restart fires only for the
// current service: a tick stamped with a since-superseded logSeq (the user
// switched services) is dropped, and restartLogs keeps the scrollback.
func TestLogRetryMsgSeqGuard(t *testing.T) {
	m := testModel(t)
	m.logSvc = "wildfly"
	m.logLines = []string{"wildfly | line", "[log follower] start failed: boom"}
	keep := append([]string(nil), m.logLines...)
	m.logSession = nil
	staleSeq := m.logSeq

	// Stale tick (user has since switched, bumping logSeq): no-op.
	m.logSeq = staleSeq + 1
	m, cmd := update(t, m, logRetryMsg{seq: staleSeq})
	if cmd != nil {
		t.Error("stale logRetryMsg scheduled a restart")
	}
	if m.logSession != nil {
		t.Error("stale logRetryMsg started a session")
	}

	// Current tick: restarts the follower WITHOUT wiping the scrollback.
	m, cmd = update(t, m, logRetryMsg{seq: m.logSeq})
	if cmd == nil || m.logSession == nil {
		t.Fatal("current logRetryMsg did not restart the follower")
	}
	if !equalStrings(m.logLines, keep) {
		t.Errorf("restart wiped scrollback: got %v, want %v", m.logLines, keep)
	}
	m.cleanup() // reap the spawned (fast-failing) follower
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestPollInflightGuards(t *testing.T) {
	m := newModel(t.TempDir())
	_, _ = m.Update(servicesTickMsg{})
	if !m.pollingServices {
		t.Fatal("services tick did not mark a poll in flight")
	}
	_, _ = m.Update(statusTickMsg{})
	if !m.pollingStatus {
		t.Fatal("status tick did not mark a poll in flight")
	}
	// Responses clear the flags so the next tick polls again.
	_, _ = m.Update(servicesMsg{})
	if m.pollingServices {
		t.Fatal("services response did not clear the in-flight flag")
	}
	_, _ = m.Update(statusMsg{})
	if m.pollingStatus {
		t.Fatal("status response did not clear the in-flight flag")
	}
}

// frameFits asserts the rendered frame never exceeds the terminal box —
// an overflowing frame makes bubbletea push the UI into scrollback.
func frameFits(t *testing.T, view string, width, height int) {
	t.Helper()
	if h := lipgloss.Height(view); h > height {
		t.Errorf("frame height %d exceeds terminal height %d", h, height)
	}
	for i, line := range strings.Split(view, "\n") {
		if w := lipgloss.Width(line); w > width {
			t.Errorf("frame line %d width %d exceeds terminal width %d", i, w, width)
		}
	}
}

func TestActionPaneFloodKeepsFrameInBox(t *testing.T) {
	m := testModel(t)
	mm, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m = mm.(*model)
	m.mode = modeActing
	m.actionName = "update"
	m.actionOut = actions.NewOutputBuffer()

	var b strings.Builder
	for i := 0; i < 300; i++ {
		fmt.Fprintf(&b, "layer%03d: %s\r\n", i, strings.Repeat("0123456789abcdef ", 12))
	}
	mm, _ = m.Update(actions.OutputMsg{Data: []byte(b.String())})
	m = mm.(*model)

	frameFits(t, m.View(), 100, 30)
}

// TestActionPanePreservesManualScroll asserts that scrolling back during a
// live run is not yanked to the bottom by the next output chunk — the
// modeActing help line advertises "pgup/pgdn scroll" and the runner emits
// OutputMsg several times a second during a chatty script.
func TestActionPanePreservesManualScroll(t *testing.T) {
	m := testModel(t)
	mm, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m = mm.(*model)
	m.mode = modeActing
	m.actionName = "update"
	m.runner = &actions.PTYRunner{} // live run: help line advertises scrolling
	m.actionOut = actions.NewOutputBuffer()

	// Enough output to overflow the pane so the viewport is scrollable.
	var b strings.Builder
	for i := 0; i < 200; i++ {
		fmt.Fprintf(&b, "line %03d\r\n", i)
	}
	m.actionOut.Feed([]byte(b.String()))
	m.refreshActionPane()
	// Sanity: a fresh feed tails to the bottom (the at-bottom default).
	if !m.actionView.AtBottom() {
		t.Fatal("first batch should have tailed to the bottom")
	}

	// User scrolls back several pages, away from the bottom.
	for i := 0; i < 3; i++ {
		m, _ = update(t, m, keyMsg("pgup"))
	}
	if m.actionView.AtBottom() {
		t.Fatal("pgup should have scrolled away from the bottom")
	}
	offsetBefore := m.actionView.YOffset

	// A new output chunk arrives mid-scroll. It must NOT yank to bottom.
	m, _ = update(t, m, actions.OutputMsg{Data: []byte("line 200\r\nline 201\r\n")})
	if m.actionView.AtBottom() {
		t.Error("output batch yanked the pane to the bottom, defeating scroll-back")
	}
	if m.actionView.YOffset != offsetBefore {
		t.Errorf("scroll position moved: YOffset %d → %d", offsetBefore, m.actionView.YOffset)
	}
}

func TestLogPaneFloodKeepsFrameInBox(t *testing.T) {
	m := testModel(t)
	mm, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m = mm.(*model)

	long := make([]string, 120)
	for i := range long {
		long[i] = strings.Repeat("wildfly | very long docker log line ", 8)
	}
	// Append lines directly and call refreshLogPane (render path under test).
	m.logLines = append(m.logLines, long...)
	if len(m.logLines) > maxLogLines {
		m.logLines = m.logLines[len(m.logLines)-maxLogLines:]
	}
	m.refreshLogPane()

	frameFits(t, m.View(), 100, 30)
}

// TestServicesPaneRowsNoWrap verifies that every service row in the services
// pane occupies exactly one visual line, even with the widest health values.
// lipgloss .Width() excludes the border (drawn outside it), so the content
// wrap width is leftWidth(36) − padding(1+1) = 34. Each row is 1 cursor col +
// formatted fields; if the formatted content exceeds 33 visible cols lipgloss
// wraps and the cursor ends up on a different visual line than the service.
func TestServicesPaneRowsNoWrap(t *testing.T) {
	services := []contract.ComposeService{
		{Service: "very-long-service-name", State: "running", Health: "unhealthy"},
		// Real service (docker-compose.yml) at 16 chars: one past svcCol=15.
		{Service: "pic-sure-logging", State: "running", Health: "healthy"},
		{Service: "wildfly", State: "running", Health: "healthy"},
		{Service: "hpds", State: "running", Health: "starting"},
		{Service: "short", State: "exited", Health: ""},
	}

	m := testModel(t)
	// Use a small height so Height(max(h-5,8))=8; border+content rows then
	// show wrapping clearly without height-padding masking the problem.
	m.height = 13 // max(13-5, 8) = 8 inner rows = title + 5 services + 2 empty
	m.layout()
	m.services = services
	m.selected = 0

	pane := m.servicesPane()

	// paneStyle uses RoundedBorder (1 col each side) so outer width = leftWidth+2.
	const outerWidth = leftWidth + 2 // 38
	paneLines := strings.Split(pane, "\n")
	for i, line := range paneLines {
		if w := lipgloss.Width(line); w > outerWidth {
			t.Errorf("services pane line %d width %d exceeds outer width %d: %q", i, w, outerWidth, line)
		}
	}

	// Verify no health keyword appears alone on its own inner line (which
	// would happen if a row wraps). Each inner line (between border rows) is
	// "│ <content> │"; we extract content by stripping ANSI then using rune
	// indexing to skip the 2-rune "│ " prefix and 2-rune " │" suffix.
	innerLines := paneLines[1 : len(paneLines)-1] // strip top/bottom border
	healthWords := []string{"unhealthy", "healthy", "starting"}
	for i, rawLine := range innerLines {
		// ansi.Strip removes escape codes; border chars (│, ╭, etc.) are plain Unicode
		plain := ansi.Strip(rawLine)
		runes := []rune(plain)
		// Each inner line: "│" + " " + <content> + " " + "│" = 2+content+2 runes
		if len(runes) >= 4 {
			// Drop "│ " prefix (2 runes) and " │" suffix (2 runes)
			content := strings.TrimRight(string(runes[2:len(runes)-2]), " ")
			for _, hw := range healthWords {
				if content == hw {
					t.Errorf("inner line %d contains only health word %q — row is wrapping: full line %q",
						i, hw, rawLine)
				}
			}
		}
	}

	// Pin the accepted svcCol=15 tradeoff: "pic-sure-logging" (16 chars)
	// clips by one char to "pic-sure-loggin" rather than wrapping — the
	// 34-col budget cannot fit 16 + full state(8) + full health(9).
	plainPane := ansi.Strip(pane)
	if !strings.Contains(plainPane, "pic-sure-loggin ") {
		t.Error(`clipped "pic-sure-loggin" row not found in services pane`)
	}
	if strings.Contains(plainPane, "pic-sure-logging") {
		t.Error(`full "pic-sure-logging" found — expected it clipped to 15 chars`)
	}
}

// Same huh root cause as the landing/wizard: esc must cancel the dashboard's
// confirm, picker, and reset dialogs (the help line advertises "esc cancel").
func TestDashboardEscCancelsConfirmAndPicker(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("X")) // uninstall → typed-word confirm
	if m.mode != modeConfirm {
		t.Fatal("X did not open the confirm")
	}
	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeNormal || m.form != nil {
		t.Errorf("esc did not cancel the confirm: mode=%v", m.mode)
	}

	m, _ = update(t, m, keyMsg("e")) // demo picker
	if m.mode != modePick {
		t.Fatal("e did not open the picker")
	}
	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeNormal || m.form != nil {
		t.Errorf("esc did not cancel the picker: mode=%v", m.mode)
	}

	m, _ = update(t, m, keyMsg("R")) // combined reset dialog
	if m.mode != modeReset {
		t.Fatal("R did not open the reset dialog")
	}
	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeNormal || m.form != nil {
		t.Errorf("esc did not cancel the reset dialog: mode=%v", m.mode)
	}
}

// TestDialogFitsNarrowPane guards against forms laid out wider than the form
// pane they render in. Below 120 cols the old WithWidth(min(width-4,76)) sized
// the form to the terminal, so lipgloss re-wrapped every line inside the
// narrower pane (content width = width-leftWidth-8) and the frame overflowed.
// At width 100 the pane content is only 56 cols, well under the old 76.
func TestDialogFitsNarrowPane(t *testing.T) {
	const w, h = 100, 30
	tests := []struct {
		name string
		open func(*model) (tea.Model, tea.Cmd)
	}{
		{"destructive confirm", func(m *model) (tea.Model, tea.Cmd) { return m.startConfirm(actions.Uninstall()) }},
		{"yes/no confirm", func(m *model) (tea.Model, tea.Cmd) { return m.startConfirm(actions.Update()) }},
		{"demo picker", func(m *model) (tea.Model, tea.Cmd) { return m.startPicker() }},
		{"combined reset", func(m *model) (tea.Model, tea.Cmd) { return m.startReset() }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := testModel(t)
			mm, _ := m.Update(tea.WindowSizeMsg{Width: w, Height: h})
			m = mm.(*model)
			tt.open(m)
			if m.form == nil {
				t.Fatal("dialog did not open")
			}

			// The form must fit the pane's content width, or it re-wraps inside
			// the pane and shears the frame.
			_, paneContent := m.actionPaneSize()
			if fw := lipgloss.Width(m.form.View()); fw > paneContent {
				t.Errorf("form view width %d exceeds pane content width %d (will re-wrap)", fw, paneContent)
			}
			// And the whole rendered frame must stay inside the terminal box.
			frameFits(t, m.View(), w, h)
		})
	}
}
