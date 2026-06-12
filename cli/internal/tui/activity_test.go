package tui

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
)

type fakeRunner struct {
	interrupted bool
	killed      bool
}

func (f *fakeRunner) WaitData() tea.Cmd     { return func() tea.Msg { return nil } }
func (f *fakeRunner) Resize(rows, cols int) {}
func (f *fakeRunner) Interrupt()            { f.interrupted = true }
func (f *fakeRunner) Kill()                 { f.killed = true }

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
	if !strings.Contains(a.view(), "enter: dashboard") {
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
	if !strings.Contains(a.view(), "enter: dashboard") {
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

// TestActivityAbortStartsGraceTimer: a confirmed abort returns a command (the
// grace tick) and the footer reports "aborting…" while the child has not yet
// exited — the force-kill offer is NOT shown until the grace elapses.
func TestActivityAbortStartsGraceTimer(t *testing.T) {
	a, fr := runningActivity(t)
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyEsc})
	_, cmd := a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if !fr.interrupted {
		t.Fatal("confirmed abort did not interrupt")
	}
	if cmd == nil {
		t.Fatal("confirmed abort did not start the grace timer")
	}
	if a.killOffered {
		t.Fatal("force-kill offered before the grace period elapsed")
	}
	view := a.view()
	if !strings.Contains(view, "aborting") {
		t.Errorf("footer does not report the aborting state:\n%s", view)
	}
	if strings.Contains(view, "force kill") {
		t.Error("force-kill offer shown before the grace period elapsed")
	}
	// K is inert before the offer is live.
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'K'}})
	if fr.killed {
		t.Error("K killed the child before the grace period elapsed")
	}
}

// TestActivityKillOfferAppearsAfterGrace: once the grace tick fires with the
// child still running, the footer offers K and K force-kills. A stale tick
// from a previous activity screen (wrong seq) is discarded.
func TestActivityKillOfferAppearsAfterGrace(t *testing.T) {
	a, fr := runningActivity(t)
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyCtrlC})
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})

	// A leftover tick from an earlier screen must not escalate this run.
	_, _ = a.update(activityKillGraceMsg{seq: a.seq - 1})
	if a.killOffered {
		t.Fatal("stale grace tick from a previous activity offered the kill")
	}

	// This run's own grace elapses while the child is still running.
	_, _ = a.update(activityKillGraceMsg{seq: a.seq})
	if !a.killOffered {
		t.Fatal("grace elapsing with a live child did not offer the force-kill")
	}
	if !strings.Contains(a.view(), "force kill") {
		t.Errorf("footer missing the force-kill offer:\n%s", a.view())
	}

	// K force-kills.
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'K'}})
	if !fr.killed {
		t.Fatal("K did not force-kill the child")
	}
}

// TestActivityDoneCancelsKillOffer: if the child exits on its own, a grace tick
// that arrives afterward must not offer the kill, and any prior offer clears.
func TestActivityDoneCancelsKillOffer(t *testing.T) {
	a, _ := runningActivity(t)
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyCtrlC})
	_, _ = a.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})

	// Child exits before the grace fires.
	_, _ = a.update(actions.DoneMsg{Code: 130})
	if a.killOffered {
		t.Fatal("kill offer set after the child already exited")
	}
	// A late grace tick must be a no-op now that the run is done.
	_, _ = a.update(activityKillGraceMsg{seq: a.seq})
	if a.killOffered {
		t.Fatal("late grace tick offered the kill on an already-finished run")
	}
	// The aborted footer (with AbortNote) is what shows, not the escalation.
	view := a.view()
	if strings.Contains(view, "force kill") {
		t.Error("force-kill offer shown on a finished run")
	}
	if !strings.Contains(view, a.act.AbortNote) {
		t.Errorf("finished-after-abort view missing AbortNote:\n%s", view)
	}
}

// TestActivityCtrlCOnFinishedScreenQuits: once the run is done, ctrl+c is the
// universal quit reflex (the child has already exited).
func TestActivityCtrlCOnFinishedScreenQuits(t *testing.T) {
	a, _ := runningActivity(t)
	_, _ = a.update(actions.DoneMsg{Code: 0})
	_, cmd := a.update(tea.KeyMsg{Type: tea.KeyCtrlC})
	if cmd == nil {
		t.Fatal("ctrl+c on the finished screen returned no command")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatalf("ctrl+c on the finished screen = %T, want tea.QuitMsg", cmd())
	}
}

// initActivity returns a sized activity for the init action (the one whose
// pipeline emits step markers), with a live fake runner.
func initActivity(t *testing.T) (*activity, *fakeRunner) {
	t.Helper()
	a := newActivity(t.TempDir(), actions.Init())
	a.setSize(80, 24)
	fr := &fakeRunner{}
	a.runner = fr
	return a, fr
}

// TestDetectPhase feeds REAL marker strings as they arrive over the PTY — the
// green-wrapped "[prefix]" exactly as scripts/lib/common.sh's info() emits it
// (\033[0;32m[init]\033[0m message) — plus the sub-scripts' own prefixes, and
// asserts the extracted phase. warn()/error() share the bracket format in
// yellow/red and must NOT match; lines with no SGR at all are the NO_COLOR
// fallback, where ⚠-prefixed warnings are skipped. Anything unrecognized
// yields "".
func TestDetectPhase(t *testing.T) {
	const g = "\x1b[0;32m" // PICSURE_GREEN (info)
	const y = "\x1b[1;33m" // PICSURE_YELLOW (warn)
	const r = "\x1b[0;31m" // PICSURE_RED (error)
	const nc = "\x1b[0m"   // PICSURE_NC
	tests := []struct {
		name string
		line string
		want string
	}{
		// init.sh top-level phases (real strings from init.sh).
		{"init clone", g + "[clone]" + nc + " Cloning repos into /x/repos", "cloning repos into /x/repos"},
		{"init build", g + "[init]" + nc + " Building container images...", "building container images..."},
		{"init start-db", g + "[init]" + nc + " Starting database...", "starting database..."},
		{"init migrate", g + "[init]" + nc + " Running database migrations...", "running database migrations..."},
		{"init seed", g + "[init]" + nc + " Seeding database...", "seeding database..."},
		{"init services", g + "[init]" + nc + " Starting services...", "starting services..."},
		// Sub-script prefixes (build-images.sh / seed-db.sh / run-migrations.sh).
		{"build image", g + "[build]" + nc + " Building pic-sure-hpds (Maven + Docker)...", "building pic-sure-hpds (maven + docker)..."},
		{"seed admin", g + "[seed]" + nc + " Creating admin user: a@b.org", "creating admin user: a@b.org"},
		{"migrate flyway", g + "[migrate]" + nc + " Running Flyway migrate...", "running flyway migrate..."},
		// warn()/error() lines — same bracket, yellow/red — must NOT become
		// the phase (real strings: init.sh:160, common.sh picsure_run_logged).
		{"warn yellow", y + "[init]" + nc + " AUTH0_CLIENT_ID is not set in .env", ""},
		{"warn force", y + "[init]" + nc + " Force mode — will regenerate all secrets", ""},
		{"error red", r + "[build]" + nc + " hpds failed. See .data/logs/build/hpds.log", ""},
		{"error env", r + "[build]" + nc + " .env not found. Run: cp .env.example .env", ""},
		// NO_COLOR fallback: a bare (no-SGR) marker still matches…
		{"no color info", "[init] Generating database passwords...", "generating database passwords..."},
		{"no color clone", "[clone] Cloning repos into /x/repos", "cloning repos into /x/repos"},
		// …but ⚠-prefixed warnings are skipped (color can't disambiguate here).
		{"no color warn", "[init] ⚠ AUTH0_CLIENT_ID is not set", ""},
		// Decoration / empty info lines are not phases.
		{"banner rule", g + "[seed]" + nc + " ======================================", ""},
		{"empty info", g + "[init]" + nc + " ", ""},
		// Unrelated bracketed output (maven/docker) must NOT match.
		{"maven info", "[INFO] Building jar", ""},
		{"docker step", "Step 3/8 : RUN make", ""},
		{"unknown prefix", g + "[deploy]" + nc + " doing things", ""},
		{"plain log", "cloning into 'pic-sure-hpds'...", ""},
		{"blank", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := detectPhase(tt.line); got != tt.want {
				t.Errorf("detectPhase(%q) = %q, want %q", tt.line, got, tt.want)
			}
		})
	}
}

// TestActivityHeaderShowsPhase: a marker chunk surfaces the phase in the running
// header; unrecognized output leaves it unchanged; the init footer carries the
// long-run note.
func TestActivityHeaderShowsPhase(t *testing.T) {
	a, _ := initActivity(t)
	if strings.Contains(a.headerLine(), "·") {
		t.Fatalf("header shows a phase before any marker: %q", a.headerLine())
	}
	if !strings.Contains(a.footerLine(), initFooterNote) {
		t.Errorf("init footer missing the long-run note: %q", a.footerLine())
	}

	_, _ = a.update(actions.OutputMsg{Data: []byte("\x1b[0;32m[init]\x1b[0m Building container images...\r\n")})
	if !strings.Contains(a.headerLine(), "building container images") {
		t.Errorf("header did not surface the build phase: %q", a.headerLine())
	}

	// Unrecognized output must leave the phase unchanged.
	_, _ = a.update(actions.OutputMsg{Data: []byte("some raw maven noise\r\n[INFO] downloading\r\n")})
	if !strings.Contains(a.headerLine(), "building container images") {
		t.Errorf("unrecognized output changed the phase: %q", a.headerLine())
	}

	// A later recognized marker advances to the latest phase.
	_, _ = a.update(actions.OutputMsg{Data: []byte("\x1b[0;32m[init]\x1b[0m Seeding database...\r\n")})
	if !strings.Contains(a.headerLine(), "seeding database") {
		t.Errorf("header did not advance to the latest phase: %q", a.headerLine())
	}
}

// TestActivityPhaseAcrossChunks: a marker split across two output chunks is
// still matched once the line completes.
func TestActivityPhaseAcrossChunks(t *testing.T) {
	a, _ := initActivity(t)
	_, _ = a.update(actions.OutputMsg{Data: []byte("\x1b[0;32m[init]\x1b[0m Starting ser")})
	if strings.Contains(a.headerLine(), "starting ser") {
		t.Fatal("phase matched on an incomplete (unterminated) line")
	}
	_, _ = a.update(actions.OutputMsg{Data: []byte("vices...\r\n")})
	if !strings.Contains(a.headerLine(), "starting services") {
		t.Errorf("split marker not matched after completion: %q", a.headerLine())
	}
}

// TestActivityNonInitHasNoPhase: actions outside the init pipeline neither track
// phases nor show the long-run footer note.
func TestActivityNonInitHasNoPhase(t *testing.T) {
	a, _ := runningActivity(t) // actions.Update()
	_, _ = a.update(actions.OutputMsg{Data: []byte("\x1b[0;32m[init]\x1b[0m Building container images...\r\n")})
	if strings.Contains(a.headerLine(), "·") {
		t.Errorf("non-init action surfaced a phase: %q", a.headerLine())
	}
	if strings.Contains(a.footerLine(), initFooterNote) {
		t.Errorf("non-init footer carries the init long-run note: %q", a.footerLine())
	}
}

// TestActivityPhaseTruncatedToWidth: a long phase is truncated so the header
// never exceeds the screen width (which would wrap and shear the layout).
func TestActivityPhaseTruncatedToWidth(t *testing.T) {
	a, _ := initActivity(t)
	a.setSize(50, 24)
	long := "Building " + strings.Repeat("very-long-image-name ", 10) + "now"
	_, _ = a.update(actions.OutputMsg{Data: []byte("\x1b[0;32m[build]\x1b[0m " + long + "\r\n")})
	if w := lipgloss.Width(a.headerLine()); w > 50 {
		t.Errorf("header width %d exceeds the 50-col screen: %q", w, a.headerLine())
	}
	if !strings.Contains(a.headerLine(), "…") {
		t.Errorf("over-long phase was not truncated with an ellipsis: %q", a.headerLine())
	}
	// The whole rendered view stays in the box too.
	for i, line := range strings.Split(a.view(), "\n") {
		if w := lipgloss.Width(line); w > 50 {
			t.Errorf("view line %d width %d exceeds 50: %q", i, w, line)
		}
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
