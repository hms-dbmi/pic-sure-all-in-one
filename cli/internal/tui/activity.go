package tui

import (
	"fmt"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
)

var (
	activityTitleStyle = lipgloss.NewStyle().Bold(true).Padding(0, 1)
	activityPaneStyle  = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
	activityHelpStyle  = lipgloss.NewStyle().Faint(true).Padding(0, 1)
	activityOKStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Bold(true).Padding(0, 1)
	activityBadStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true).Padding(0, 1)
	activityWarnStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Bold(true).Padding(0, 1)
)

// activityClosedMsg tells the app to leave the activity screen.
type activityClosedMsg struct{ openDashboard bool }

type activityTickMsg struct{}

// runnerHandle abstracts *actions.PTYRunner for tests.
type runnerHandle interface {
	WaitData() tea.Cmd
	Resize(rows, cols int)
	Interrupt()
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

	confirmingAbort bool
	aborted         bool
	done            bool
	code            int
	err             error
}

func newActivity(root string, act actions.Action) *activity {
	return &activity{root: root, act: act, out: actions.NewOutputBuffer(), started: time.Now()}
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

func (a *activity) update(msg tea.Msg) (*activity, tea.Cmd) {
	switch msg := msg.(type) {
	case actions.OutputMsg:
		a.out.Feed(msg.Data)
		a.refreshContent()
		if a.runner != nil {
			return a, a.runner.WaitData()
		}
		return a, nil

	case actions.DoneMsg:
		a.done, a.code, a.err = true, msg.Code, msg.Err
		a.runner = nil
		// Completion beats a pending abort question: dismiss it so 'y' can't
		// claim an abort of a run that already finished.
		a.confirmingAbort = false
		a.elapsed = time.Since(a.started).Round(time.Second)
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
		case "n", "N", "esc":
			a.confirmingAbort = false
		}
		return a, nil
	}

	if !a.done {
		switch key {
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
	case "pgup", "pgdown", "up", "down", "home", "end":
		var cmd tea.Cmd
		a.vp, cmd = a.vp.Update(msg)
		return a, cmd
	}
	return a, nil
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
	return fmt.Sprintf("%s — running %s", a.act.Name, a.elapsed)
}

func (a *activity) footerLine() string {
	switch {
	case a.confirmingAbort:
		return activityWarnStyle.Render(fmt.Sprintf("⚠ %s is still running — abort it? (y/n)", a.act.Name))
	case !a.done:
		return activityHelpStyle.Render("esc/ctrl+c abort · pgup/pgdn scroll")
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
