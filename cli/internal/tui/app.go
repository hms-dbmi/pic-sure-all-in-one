package tui

import (
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/dashboard"
)

// Screen identifies the active top-level screen.
type Screen int

const (
	ScreenLanding Screen = iota
	ScreenDashboard
	ScreenActivity
	ScreenWizard
)

// Options configures the unified TUI.
type Options struct {
	Root       string
	Start      Screen
	Animations bool
}

// openWizardMsg asks the app to open the embedded wizard screen.
type openWizardMsg struct{ reconfigure bool }

// Run starts the unified TUI and blocks until quit.
func Run(o Options) error {
	program := tea.NewProgram(newApp(o), tea.WithAltScreen())
	_, err := program.Run()
	return err
}

type app struct {
	opts          Options
	width, height int

	screen   Screen
	landing  *landing
	dash     tea.Model
	activity *activity
	wizard   *wizardScreen
}

func newApp(o Options) *app {
	a := &app{opts: o, screen: ScreenLanding}
	a.landing = newLanding(o.Root, envExists(o.Root), o.Animations)
	if o.Start == ScreenDashboard {
		a.dash = dashboard.New(o.Root)
		a.screen = ScreenDashboard
	}
	return a
}

func envExists(root string) bool {
	_, err := os.Stat(filepath.Join(root, ".env"))
	return err == nil
}

func (a *app) Init() tea.Cmd {
	if a.screen == ScreenDashboard {
		return a.dash.Init()
	}
	return a.landing.startAnimations()
}

func (a *app) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		a.width, a.height = msg.Width, msg.Height
		a.landing.setSize(msg.Width, msg.Height)
		if a.activity != nil {
			a.activity.setSize(msg.Width, msg.Height)
		}
		if a.wizard != nil {
			a.wizard.setSize(msg.Width, msg.Height)
		}
		if a.dash != nil {
			var cmd tea.Cmd
			a.dash, cmd = a.dash.Update(msg)
			return a, cmd
		}
		return a, nil

	// --- navigation ---
	case openDashboardMsg:
		return a.openDashboard()

	case dashboard.BackMsg:
		a.dash = nil
		return a.openLanding()

	case runActionMsg:
		a.landing.stopAnimations()
		a.activity = newActivity(a.opts.Root, msg.act)
		a.activity.setSize(a.width, a.height)
		a.screen = ScreenActivity
		return a, a.activity.start()

	case activityClosedMsg:
		a.activity = nil
		if msg.openDashboard {
			return a.openDashboard()
		}
		return a.openLanding()

	case openWizardMsg:
		s, err := newWizardScreen(a.opts.Root, msg.reconfigure)
		if err != nil {
			a.landing.result = "setup failed: " + err.Error()
			return a, nil
		}
		a.landing.stopAnimations()
		s.setSize(a.width, a.height)
		a.wizard = s
		a.screen = ScreenWizard
		return a, s.init()

	case wizardClosedMsg:
		a.wizard = nil
		if msg.aborted {
			a.landing.result = "setup cancelled — nothing written"
		}
		return a, a.openLandingCmd()

	case wizardWritesDoneMsg:
		a.wizard = nil
		if msg.err != nil {
			a.landing.result = "setup failed: " + msg.err.Error()
			return a, a.openLandingCmd()
		}
		// Consent already given at the wizard's confirm-summary: run init.sh
		// in the activity screen with no further dialog.
		return a.Update(runActionMsg{act: actions.Init()})
	}

	// --- route everything else to the active screen ---
	switch a.screen {
	case ScreenDashboard:
		if a.dash == nil {
			return a, nil
		}
		var cmd tea.Cmd
		a.dash, cmd = a.dash.Update(msg)
		return a, cmd
	case ScreenActivity:
		if a.activity == nil {
			return a, nil
		}
		var cmd tea.Cmd
		a.activity, cmd = a.activity.update(msg)
		return a, cmd
	case ScreenWizard:
		if a.wizard == nil {
			return a, nil
		}
		var cmd tea.Cmd
		a.wizard, cmd = a.wizard.update(msg)
		return a, cmd
	default:
		var cmd tea.Cmd
		a.landing, cmd = a.landing.update(msg)
		return a, cmd
	}
}

func (a *app) openDashboard() (tea.Model, tea.Cmd) {
	a.landing.stopAnimations()
	a.dash = dashboard.New(a.opts.Root)
	a.screen = ScreenDashboard
	// Deliver the current size before Init so the first frame is laid out.
	var cmd tea.Cmd
	a.dash, cmd = a.dash.Update(tea.WindowSizeMsg{Width: a.width, Height: a.height})
	return a, tea.Batch(cmd, a.dash.Init())
}

func (a *app) openLandingCmd() tea.Cmd {
	a.screen = ScreenLanding
	a.landing.setEnvExists(envExists(a.opts.Root))
	return a.landing.startAnimations()
}

func (a *app) openLanding() (tea.Model, tea.Cmd) {
	return a, a.openLandingCmd()
}

func (a *app) View() string {
	switch a.screen {
	case ScreenDashboard:
		if a.dash != nil {
			return a.dash.View()
		}
	case ScreenActivity:
		if a.activity != nil {
			return a.activity.view()
		}
	case ScreenWizard:
		if a.wizard != nil {
			return a.wizard.view()
		}
	}
	return a.landing.view()
}
