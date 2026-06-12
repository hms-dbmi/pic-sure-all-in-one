package tui

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"
)

var (
	activityTitleStyle = lipgloss.NewStyle().Bold(true).Padding(0, 1)
	activityPaneStyle  = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
	activityHelpStyle  = lipgloss.NewStyle().Faint(true).Padding(0, 1)
	activityOKStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Bold(true).Padding(0, 1)
	activityBadStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true).Padding(0, 1)
	activityWarnStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Bold(true).Padding(0, 1)
)

// initFooterNote sets first-run expectations on the init screen specifically,
// where the build/clone/seed pipeline can run 20–30 minutes (the dashboard and
// other actions finish in seconds-to-minutes, so they get no such note).
const initFooterNote = "first run takes ~20–30 minutes"

// phaseLinePattern matches the scripts' own info() markers after ANSI is
// stripped: "[PREFIX] message", where PREFIX is one of the init pipeline's log
// prefixes (scripts/lib/common.sh's info() emits "[$LOG_PREFIX] $*", with the
// bracket wrapped in green that we strip first). Capturing only these known
// prefixes keeps unrelated bracketed output (e.g. docker/maven "[INFO]" lines)
// from being mistaken for a phase. Tolerant by construction: anything that does
// not match leaves the current phase unchanged.
var phaseLinePattern = regexp.MustCompile(`^\[(init|clone|build|seed|migrate)\]\s+(.*)$`)

// phaseDecoration matches a marker message that is pure decoration (the banner
// rules like "======") or empty — surfacing those as a phase would be noise.
var phaseDecoration = regexp.MustCompile(`^[^\p{L}\p{N}]*$`)

// detectPhase extracts a short phase hint from one raw output line, or "" if
// the line is not a recognized step marker (the caller then leaves the phase
// unchanged). It strips ANSI first, matches the scripts' "[prefix] message"
// info() format, and returns the message lowercased and trimmed — surfacing the
// scripts' own words rather than inventing phase names. Cheap: one ANSI strip
// and one regexp match per line. Kept as a free function so it is unit-testable
// against real captured marker strings.
func detectPhase(line string) string {
	line = strings.TrimSpace(ansi.Strip(line))
	m := phaseLinePattern.FindStringSubmatch(line)
	if m == nil {
		return ""
	}
	msg := strings.TrimSpace(m[2])
	if phaseDecoration.MatchString(msg) {
		return "" // banner rule or empty info line: not a phase
	}
	return strings.ToLower(msg)
}

// activityClosedMsg tells the app to leave the activity screen.
type activityClosedMsg struct{ openDashboard bool }

type activityTickMsg struct{}

// abortGracePeriod is how long a confirmed abort waits for the child to honor
// the ctrl-c SIGINT before the screen offers a force-kill.
const abortGracePeriod = 10 * time.Second

// activityKillGraceMsg fires abortGracePeriod after a confirmed abort. If the
// child still hasn't exited, the footer offers the force-kill escalation. seq
// identifies the activity whose abort armed the timer: a tick armed by run A
// can outlive A's screen and be routed to a later activity B by the app — the
// stamp makes B discard it instead of cutting its own grace short (the same
// guard the dashboard pane uses).
type activityKillGraceMsg struct{ seq int }

// activitySeq numbers activity screens so stale grace ticks are identifiable.
// Only touched from the bubbletea update goroutine (newActivity is called from
// the app's Update), so a plain int is race-free.
var activitySeq int

// runnerHandle abstracts *actions.PTYRunner for tests.
type runnerHandle interface {
	WaitData() tea.Cmd
	Resize(rows, cols int)
	Interrupt()
	Kill()
}

// startRunner is a seam: tests replace it to avoid spawning real PTYs.
var startRunner = func(root string, act actions.Action, rows, cols int) (runnerHandle, error) {
	return actions.StartPTY(root, act, rows, cols)
}

// activity is the full-screen runner for one menu-launched action.
type activity struct {
	root string
	act  actions.Action

	runner runnerHandle
	vp     viewport.Model
	out    *actions.OutputBuffer

	width, height int
	started       time.Time
	elapsed       time.Duration

	// phase is the latest step marker matched from the script's output, shown
	// in the running header so a long run (init) is not just "running 0s" over
	// raw logs. phaseScan accumulates the trailing partial line across output
	// chunks so a marker split mid-line is still matched once it completes. Both
	// are only maintained for actions whose pipeline emits markers (init today).
	phase     string
	phaseScan []byte

	confirmingAbort bool
	aborted         bool
	killOffered     bool // grace period elapsed, child still running: offer K
	seq             int  // this run's activitySeq; stamps grace ticks so stale ones are discarded
	done            bool
	code            int
	err             error
}

func newActivity(root string, act actions.Action) *activity {
	activitySeq++
	return &activity{root: root, act: act, out: actions.NewOutputBuffer(), started: time.Now(), seq: activitySeq}
}

// start launches the script; on start failure the screen opens directly in
// its failed state (the footer shows the error).
func (a *activity) start() tea.Cmd {
	rows, cols := a.paneSize()
	runner, err := startRunner(a.root, a.act, rows, cols)
	if err != nil {
		a.done, a.err = true, err
		return nil
	}
	a.runner = runner
	return tea.Batch(runner.WaitData(), a.tickElapsed())
}

func (a *activity) tickElapsed() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return activityTickMsg{} })
}

func (a *activity) setSize(width, height int) {
	a.width, a.height = width, height
	rows, cols := a.paneSize()
	a.vp.Width, a.vp.Height = cols, rows
	a.refreshContent() // re-wrap at the new width
	if a.runner != nil {
		a.runner.Resize(rows, cols)
	}
}

// refreshContent re-renders the sanitized scrollback into the viewport,
// hard-wrapped at its width (ANSI-aware) so long script lines can never
// overflow the pane and shear the border. Autoscroll only when already
// tailing, so users can scroll back during a long run.
func (a *activity) refreshContent() {
	content := a.out.String()
	if a.vp.Width > 0 {
		content = ansi.Hardwrap(content, a.vp.Width, true)
	}
	atBottom := a.vp.AtBottom()
	a.vp.SetContent(content)
	if atBottom {
		a.vp.GotoBottom()
	}
}

func (a *activity) paneSize() (rows, cols int) {
	return max(a.height-6, 5), max(a.width-6, 20)
}

// tracksPhases reports whether this action's pipeline emits step markers worth
// surfacing in the header (and the long-run footer note). Only init.sh's
// clone/build/seed/migrate pipeline runs long enough and prints enough top-level
// markers to warrant it; other actions stay on the plain "running 0s" header.
func (a *activity) tracksPhases() bool {
	return a.act.Script == scripts.Init
}

// scanPhase updates a.phase from the new raw chunk only (never the whole
// buffer), so it stays cheap on a chatty stream. It splits the accumulated
// trailing partial + new bytes on newlines, runs detectPhase on each COMPLETE
// line, and keeps the last (unterminated) fragment for the next chunk — so a
// marker split across chunks is matched once it completes. An unrecognized line
// leaves a.phase unchanged.
func (a *activity) scanPhase(data []byte) {
	if !a.tracksPhases() {
		return
	}
	a.phaseScan = append(a.phaseScan, data...)
	for {
		i := bytes.IndexByte(a.phaseScan, '\n')
		if i < 0 {
			break
		}
		line := string(a.phaseScan[:i])
		a.phaseScan = a.phaseScan[i+1:]
		if p := detectPhase(line); p != "" {
			a.phase = p
		}
	}
	// Cap the unterminated fragment so a never-newline stream can't grow it
	// without bound (matches the output buffer's pathological-line guard).
	if len(a.phaseScan) > maxPhaseScanLen {
		a.phaseScan = a.phaseScan[len(a.phaseScan)-maxPhaseScanLen:]
	}
}

// maxPhaseScanLen bounds the carried partial line; a marker line is never this
// long, so truncation only ever discards leading junk on a pathological stream.
const maxPhaseScanLen = 8 * 1024

func (a *activity) update(msg tea.Msg) (*activity, tea.Cmd) {
	switch msg := msg.(type) {
	case actions.OutputMsg:
		a.out.Feed(msg.Data)
		a.scanPhase(msg.Data)
		a.refreshContent()
		if a.runner != nil {
			return a, a.runner.WaitData()
		}
		return a, nil

	case actions.DoneMsg:
		a.done, a.code, a.err = true, msg.Code, msg.Err
		a.runner = nil
		// Completion beats a pending abort question: dismiss it so 'y' can't
		// claim an abort of a run that already finished. It also cancels a
		// pending kill-grace offer — the child exited on its own.
		a.confirmingAbort = false
		a.killOffered = false
		a.elapsed = time.Since(a.started).Round(time.Second)
		return a, nil

	case activityKillGraceMsg:
		// The grace period after a confirmed abort elapsed. Discard a stale
		// tick armed by a previous activity screen, then — if the child still
		// hasn't exited — surface the force-kill escalation in the footer.
		if msg.seq != a.seq {
			return a, nil
		}
		if a.aborted && !a.done {
			a.killOffered = true
		}
		return a, nil

	case activityTickMsg:
		if a.done {
			return a, nil
		}
		a.elapsed = time.Since(a.started).Round(time.Second)
		return a, a.tickElapsed()

	case tea.KeyMsg:
		return a.handleKey(msg)
	}
	return a, nil
}

func (a *activity) handleKey(msg tea.KeyMsg) (*activity, tea.Cmd) {
	key := msg.String()

	if a.confirmingAbort {
		switch key {
		case "y", "Y", "ctrl+c": // ctrl+c is a reflexive second press — treat as "yes, abort"
			a.confirmingAbort = false
			if a.done {
				return a, nil // run finished while confirming; nothing to abort
			}
			a.aborted = true
			if a.runner != nil {
				a.runner.Interrupt()
			}
			// Start the grace timer: if the child ignores the SIGINT, the
			// footer will offer a force-kill once it elapses.
			return a, a.killGrace()
		case "n", "N", "esc":
			a.confirmingAbort = false
		}
		return a, nil
	}

	if !a.done {
		switch key {
		case "K":
			// Escalation: only live once the grace period elapsed with the
			// child still running (footer advertises it then).
			if a.killOffered && a.runner != nil {
				a.runner.Kill()
			}
			return a, nil
		case "esc", "ctrl+c":
			a.confirmingAbort = true
			return a, nil
		case "pgup", "pgdown", "up", "down", "home", "end":
			var cmd tea.Cmd
			a.vp, cmd = a.vp.Update(msg)
			return a, cmd
		}
		return a, nil
	}

	// done
	switch key {
	case "enter":
		if a.code == 0 && a.err == nil && !a.aborted {
			return a, func() tea.Msg { return activityClosedMsg{openDashboard: true} }
		}
	case "esc", "q":
		return a, func() tea.Msg { return activityClosedMsg{} }
	case "ctrl+c":
		// The child has already exited, nothing is at risk: honor the
		// universal quit reflex instead of swallowing it.
		return a, tea.Quit
	case "pgup", "pgdown", "up", "down", "home", "end":
		var cmd tea.Cmd
		a.vp, cmd = a.vp.Update(msg)
		return a, cmd
	}
	return a, nil
}

// killGrace schedules the force-kill offer for abortGracePeriod after a
// confirmed abort, stamped with this run's seq so a later screen ignores it.
func (a *activity) killGrace() tea.Cmd {
	seq := a.seq
	return tea.Tick(abortGracePeriod, func(time.Time) tea.Msg { return activityKillGraceMsg{seq: seq} })
}

func (a *activity) view() string {
	title := activityTitleStyle.Render(a.headerLine())
	pane := activityPaneStyle.Width(max(a.width-4, 22)).Render(a.vp.View())
	return lipgloss.JoinVertical(lipgloss.Left, title, pane, a.footerLine())
}

func (a *activity) headerLine() string {
	if a.done {
		return fmt.Sprintf("%s — finished", a.act.Name)
	}
	base := fmt.Sprintf("%s — running %s", a.act.Name, a.elapsed)
	if a.phase == "" {
		return base
	}
	// Append the latest matched phase, truncated so the header never exceeds
	// the screen width and wraps (which would shear the layout). The title
	// style adds 1 col of padding each side; budget for that plus the " · "
	// separator. With no known width yet, fall back to a generous default so
	// the phase still shows in tests that render before the first resize.
	width := a.width
	if width <= 0 {
		width = 80
	}
	const sep = " · "
	avail := width - 2 - lipgloss.Width(base) - lipgloss.Width(sep)
	if avail < 8 {
		return base // too narrow to add a phase legibly
	}
	return base + sep + ansi.Truncate(a.phase, avail, "…")
}

func (a *activity) footerLine() string {
	switch {
	case a.confirmingAbort:
		return activityWarnStyle.Render(fmt.Sprintf("⚠ %s is still running — abort it? (y/n)", a.act.Name))
	case a.killOffered && !a.done:
		// Grace period elapsed and the child is still alive — escalate.
		return activityWarnStyle.Render("child ignoring interrupt — K: force kill") +
			activityHelpStyle.Render("  pgup/pgdn scroll")
	case a.aborted && !a.done:
		return activityWarnStyle.Render("aborting — sent ctrl-c, waiting for the child to exit…") +
			activityHelpStyle.Render("  pgup/pgdn scroll")
	case !a.done:
		help := "esc/ctrl+c abort · pgup/pgdn scroll"
		// Append the first-run note only on the init screen and only when it
		// fits the width — at narrow widths the longer footer would wrap and
		// shear the frame (the abort/scroll hint always takes priority).
		if a.tracksPhases() {
			withNote := help + " · " + initFooterNote
			if a.width <= 0 || lipgloss.Width(withNote)+2 <= a.width {
				help = withNote
			}
		}
		return activityHelpStyle.Render(help)
	case a.aborted:
		return activityWarnStyle.Render("aborted — "+a.act.AbortNote) +
			activityHelpStyle.Render("  esc/q: back to menu")
	case a.err != nil:
		return activityBadStyle.Render(fmt.Sprintf("✗ failed to run: %v", a.err)) +
			activityHelpStyle.Render("  esc/q: back to menu")
	case a.code != 0:
		return activityBadStyle.Render(fmt.Sprintf("✗ exited %d", a.code)) +
			activityHelpStyle.Render("  esc/q: back to menu · pgup/pgdn scroll")
	default:
		return activityOKStyle.Render(fmt.Sprintf("✓ done in %s", a.elapsed)) +
			activityHelpStyle.Render("  enter: open dashboard · esc/q: back to menu")
	}
}
