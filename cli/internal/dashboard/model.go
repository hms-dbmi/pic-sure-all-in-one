package dashboard

import (
	"fmt"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/contract"
)

type mode int

const (
	modeNormal mode = iota
	modeConfirm
	modePick
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
	pending       *actions.Action

	runner     *actions.PTYRunner
	actionView viewport.Model
	actionOut  *actions.OutputBuffer
	actionName string
	lastResult string
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
		if m.form != nil && (m.mode == modeConfirm || m.mode == modePick) {
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
		if msg.Err != nil {
			m.lastResult = fmt.Sprintf("%s failed to start: %v", name, msg.Err)
		} else if msg.Code == 0 {
			m.lastResult = fmt.Sprintf("%s succeeded (exit 0)", name)
		} else {
			m.lastResult = fmt.Sprintf("%s FAILED (exit %d)", name, msg.Code)
		}
		m.runner = nil
		// Stay in modeActing so the output remains readable until esc.
		m.pollingServices, m.pollingStatus = true, true
		return m, tea.Batch(pollServices(m.root), pollStatus(m.root))

	case tea.KeyMsg:
		return m.handleKey(msg)
	}

	// Forms consume every message type while active (spinners, blinks, ...).
	if m.mode == modeConfirm || m.mode == modePick {
		return m.updateForm(msg)
	}
	return m, nil
}

func (m *model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.mode {
	case modeConfirm, modePick:
		// huh ships its esc binding disabled; the help line advertises
		// "esc cancel" — intercept it (same fix as the wizard and landing).
		if msg.String() == "esc" {
			m.form = nil
			m.pending = nil
			m.mode = modeNormal
			return m, nil
		}
		return m.updateForm(msg)

	case modeActing:
		switch msg.String() {
		case "ctrl+c":
			if m.runner != nil {
				m.runner.Interrupt()
				return m, nil
			}
			return m, nil
		case "esc", "q":
			if m.runner == nil { // finished → close the pane
				m.mode = modeNormal
				m.actionOut = nil
				return m, nil
			}
			return m, nil
		case "pgup", "pgdown", "up", "down", "home", "end":
			var cmd tea.Cmd
			m.actionView, cmd = m.actionView.Update(msg)
			return m, cmd
		}
		return m, nil
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
		return m.startConfirm(actions.Preflight())
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
		return m.startConfirm(actions.Reset())
	case "X":
		return m.startConfirm(actions.Uninstall())
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
