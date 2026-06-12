package dashboard

import (
	"fmt"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/contract"
)

// abortGracePeriod is how long a confirmed pane abort waits for the child to
// honor the ctrl-c SIGINT before the pane offers a force-kill (mirrors the
// activity screen).
const abortGracePeriod = 10 * time.Second

// killGraceMsg fires abortGracePeriod after a confirmed abort. If the child is
// still running, the pane footer escalates to the force-kill offer. seq is the
// actionSeq of the run whose abort armed the timer: a timer armed during run A
// stays pending in the runtime even after A exits, so without the stamp it
// could fire into a later aborted run B and cut B's grace period short (same
// staleness pattern as logSeq/sessionID for the log follower).
type killGraceMsg struct{ seq int }

// killGrace schedules the force-kill offer for the run identified by seq.
func killGrace(seq int) tea.Cmd {
	return tea.Tick(abortGracePeriod, func(time.Time) tea.Msg { return killGraceMsg{seq: seq} })
}

// runnerHandle abstracts *actions.PTYRunner so tests can substitute a fake
// (mirrors the activity screen's seam).
type runnerHandle interface {
	WaitData() tea.Cmd
	Resize(rows, cols int)
	Interrupt()
	Kill()
}

// startPTY is a seam: tests replace it to avoid spawning real PTYs.
var startPTY = func(root string, act actions.Action, rows, cols int) (runnerHandle, error) {
	return actions.StartPTY(root, act, rows, cols)
}

type mode int

const (
	modeNormal mode = iota
	modeConfirm
	modePick
	modeReset
	modeActing
)

const (
	leftWidth     = 36
	summaryHeight = 11
	maxLogLines   = 2000
)

type model struct {
	root          string
	width, height int

	services        []contract.ComposeService
	servicesErr     error
	pollingServices bool // a compose ps poll is in flight
	status          *contract.Status
	statusErr       error
	pollingStatus   bool // a status.sh --json poll is in flight
	selected        int

	logView    viewport.Model
	logLines   []string
	logSvc     string
	logSession *logSession
	logSeq     int

	mode          mode
	form          *huh.Form
	confirmOK     bool
	confirmText   string
	pickedDataset string
	resetScope    string // "keep" or "all" — set only while mode == modeReset
	resetRepos    bool   // reset-sibling-repos toggle — set only while modeReset
	pending       *actions.Action

	runner          runnerHandle
	actionView      viewport.Model
	actionOut       *actions.OutputBuffer
	actionName      string
	actionAbortNote string // the running action's re-run-safety note, shown after an abort
	actionSeq       int    // increments per startAction; stamps grace timers so stale ones are discarded
	lastResult      string

	// Abort state for the action pane (mirrors the activity screen): a bare
	// ctrl+c/esc first asks to confirm; a confirmed abort sends ctrl-c and, if
	// the child ignores it, the pane footer offers a force-kill after a grace.
	// confirmingAbort/aborted/killOffered describe the LIVE run and reset when
	// it exits; lastAborted is the finished-pane display flag (DoneMsg latches
	// it from aborted so the AbortNote shows until the pane closes).
	confirmingAbort bool
	aborted         bool
	killOffered     bool
	lastAborted     bool
}

func newModel(root string) *model {
	return &model{root: root}
}

func (m *model) Init() tea.Cmd {
	m.pollingServices, m.pollingStatus = true, true
	return tea.Batch(pollServices(m.root), pollStatus(m.root), servicesTick(), statusTick())
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.layout()
		if m.runner != nil {
			rows, cols := m.actionPaneSize()
			m.runner.Resize(rows, cols)
		}
		// Re-size an open dialog to the new pane width; huh recomputes its
		// group viewport geometry only in its WindowSizeMsg handler, and this
		// branch returns without routing the resize to the form.
		if m.form != nil && (m.mode == modeConfirm || m.mode == modePick || m.mode == modeReset) {
			m.form = m.sizeForm(m.form)
		}
		return m, nil

	case servicesTickMsg:
		cmds := []tea.Cmd{servicesTick()}
		// One poll in flight at a time: a slow docker daemon must not stack
		// a new compose ps on every tick.
		if !m.pollingServices {
			m.pollingServices = true
			cmds = append(cmds, pollServices(m.root))
		}
		// Restart a dead log follower for the still-selected service.
		if m.logSession == nil && m.logSvc != "" {
			cmds = append(cmds, m.followLogs(m.logSvc))
		}
		return m, tea.Batch(cmds...)

	case statusTickMsg:
		if m.mode == modeActing || m.pollingStatus {
			return m, statusTick() // skip while a script runs or a poll is in flight
		}
		m.pollingStatus = true
		return m, tea.Batch(pollStatus(m.root), statusTick())

	case servicesMsg:
		m.pollingServices = false
		m.servicesErr = msg.err
		if msg.err == nil {
			m.services = msg.services
			if m.selected >= len(m.services) {
				m.selected = max(len(m.services)-1, 0)
			}
			if m.logSvc == "" && len(m.services) > 0 {
				return m, m.followLogs(m.services[m.selected].Service)
			}
		}
		return m, nil

	case statusMsg:
		m.pollingStatus = false
		m.status, m.statusErr = msg.status, msg.err
		return m, nil

	case logLinesMsg:
		if m.logSession == nil || msg.sessionID != m.logSession.id {
			return m, nil // stale session
		}
		m.logLines = append(m.logLines, msg.lines...)
		if len(m.logLines) > maxLogLines {
			m.logLines = m.logLines[len(m.logLines)-maxLogLines:]
		}
		m.refreshLogPane()
		return m, m.logSession.waitLines()

	case logClosedMsg:
		if m.logSession != nil && msg.sessionID == m.logSession.id {
			m.logSession = nil // servicesTick will restart it
		}
		return m, nil

	case actions.OutputMsg:
		if m.actionOut == nil {
			return m, nil // pane already closed; stray chunk
		}
		m.actionOut.Feed(msg.Data)
		m.refreshActionPane()
		if m.runner != nil {
			return m, m.runner.WaitData()
		}
		return m, nil

	case actions.DoneMsg:
		name := m.actionName
		m.lastAborted = m.aborted // latch for the finished-pane AbortNote
		switch {
		case m.lastAborted:
			m.lastResult = fmt.Sprintf("%s aborted (exit %d)", name, msg.Code)
		case msg.Err != nil:
			m.lastResult = fmt.Sprintf("%s failed to start: %v", name, msg.Err)
		case msg.Code == 0:
			m.lastResult = fmt.Sprintf("%s succeeded (exit 0)", name)
		default:
			m.lastResult = fmt.Sprintf("%s FAILED (exit %d)", name, msg.Code)
		}
		m.runner = nil
		// The child exited: clear ALL live-run abort state (belt and braces on
		// top of the seq guard — a stale grace timer must find nothing to act
		// on, and a fresh run must start from a clean slate).
		m.confirmingAbort = false
		m.aborted = false
		m.killOffered = false
		// Stay in modeActing so the output remains readable until esc.
		m.pollingServices, m.pollingStatus = true, true
		return m, tea.Batch(pollServices(m.root), pollStatus(m.root))

	case killGraceMsg:
		// Grace period after a confirmed abort elapsed. Discard a stale timer
		// armed by an earlier run — only the current run's abort may escalate,
		// or run B's 10s grace would be cut short by run A's leftover tick.
		if msg.seq != m.actionSeq {
			return m, nil
		}
		if m.aborted && m.runner != nil {
			m.killOffered = true
		}
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)
	}

	// Forms consume every message type while active (spinners, blinks, ...).
	if m.mode == modeConfirm || m.mode == modePick || m.mode == modeReset {
		return m.updateForm(msg)
	}
	return m, nil
}

func (m *model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.mode {
	case modeConfirm, modePick, modeReset:
		// huh ships its esc binding disabled; the help line advertises
		// "esc cancel" — intercept it (same fix as the wizard and landing).
		if msg.String() == "esc" {
			m.form = nil
			m.pending = nil
			m.resetScope, m.resetRepos = "", false
			m.mode = modeNormal
			return m, nil
		}
		return m.updateForm(msg)

	case modeActing:
		return m.handleActingKey(msg)
	}

	// modeNormal
	switch msg.String() {
	case "q", "ctrl+c":
		m.cleanup()
		return m, tea.Quit
	case "esc":
		m.cleanup()
		return m, func() tea.Msg { return BackMsg{} }
	case "up", "k":
		return m, m.moveSelection(-1)
	case "down", "j":
		return m, m.moveSelection(1)
	case "pgup", "pgdown", "home", "end":
		var cmd tea.Cmd
		m.logView, cmd = m.logView.Update(msg)
		return m, cmd
	case "u":
		return m.startConfirm(actions.Update())
	case "p":
		// Read-only: runs immediately, no confirm (spec consent model — same
		// as the landing's Preflight check entry).
		return m.startAction(actions.Preflight())
	case "m":
		return m.startConfirm(actions.Migrate())
	case "s":
		return m.startConfirm(actions.SeedDB())
	case "r":
		if svc := m.selectedService(); svc != "" {
			return m.startConfirm(actions.Restart(svc))
		}
		return m, nil
	case "e":
		return m.startPicker()
	case "R":
		return m.startReset()
	case "X":
		return m.startConfirm(actions.Uninstall())
	}
	return m, nil
}

// handleActingKey handles keys in the action pane. It mirrors the activity
// screen: a bare ctrl+c/esc on a live run first asks to confirm; a confirmed
// abort sends ctrl-c and, if the child ignores it past the grace period, the
// footer offers a force-kill (K). On a finished pane esc/q close it and ctrl+c
// quits (matching q), since the child has already exited.
func (m *model) handleActingKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Inline confirm (no huh — the activity screen doesn't use one either).
	if m.confirmingAbort {
		switch msg.String() {
		case "y", "Y", "ctrl+c": // reflexive second ctrl+c = "yes, abort"
			m.confirmingAbort = false
			if m.runner == nil {
				return m, nil // finished while confirming; nothing to abort
			}
			m.aborted = true
			m.runner.Interrupt()
			return m, killGrace(m.actionSeq)
		case "n", "N", "esc":
			m.confirmingAbort = false
		}
		return m, nil
	}

	if m.runner == nil { // finished pane
		switch msg.String() {
		case "esc", "q":
			m.mode = modeNormal
			m.actionOut = nil
			return m, nil
		case "ctrl+c":
			// Child already exited, nothing at risk — quit like q does in
			// normal mode (the universal reflex), after releasing children.
			m.cleanup()
			return m, tea.Quit
		case "pgup", "pgdown", "up", "down", "home", "end":
			var cmd tea.Cmd
			m.actionView, cmd = m.actionView.Update(msg)
			return m, cmd
		}
		return m, nil
	}

	// Live run.
	switch msg.String() {
	case "K":
		// Escalation: only live once the grace period elapsed with the child
		// still running (the footer advertises it then).
		if m.killOffered {
			m.runner.Kill()
		}
		return m, nil
	case "ctrl+c", "esc":
		m.confirmingAbort = true
		return m, nil
	case "pgup", "pgdown", "up", "down", "home", "end":
		var cmd tea.Cmd
		m.actionView, cmd = m.actionView.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m *model) moveSelection(delta int) tea.Cmd {
	if len(m.services) == 0 {
		return nil
	}
	next := m.selected + delta
	if next < 0 {
		next = 0
	}
	if next >= len(m.services) {
		next = len(m.services) - 1
	}
	if next == m.selected {
		return nil
	}
	m.selected = next
	return m.followLogs(m.services[m.selected].Service)
}

func (m *model) selectedService() string {
	if m.selected < len(m.services) {
		return m.services[m.selected].Service
	}
	return ""
}

// followLogs switches the log pane to a service, replacing any live session.
func (m *model) followLogs(service string) tea.Cmd {
	if m.logSession != nil {
		m.logSession.stop()
	}
	m.logSeq++
	m.logSvc = service
	m.logLines = nil
	m.logView.SetContent("")
	m.logSession = startLogSession(m.root, service, m.logSeq)
	return m.logSession.waitLines()
}

// cleanup releases child processes on quit. The PTY child is interrupted —
// never silently killed mid-mutation — and the screen is restored by Bubble
// Tea's normal teardown.
func (m *model) cleanup() {
	if m.logSession != nil {
		m.logSession.stop()
	}
	if m.runner != nil {
		m.runner.Interrupt()
	}
}
