package tui

import (
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"

	picexec "github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/exec"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/wizard"
)

// The embedded wizard host (spec: Wizard screen, M2). Calm background — no
// starfield. Phase 1 is the shared field form, phase 2 the confirm-summary;
// on consent the changed keys are written via scripts/env-set.sh and init.sh
// runs in the activity screen.
type wizardPhase int

const (
	wizardMain wizardPhase = iota
	wizardConfirm
	// wizardWriting is the terminal phase: writeCmd has been issued and the
	// screen swallows every further message. Without it, a huh cursor-blink
	// tick arriving between issuing writeCmd and the app handling
	// wizardWritesDoneMsg would re-enter the StateCompleted branch and fire
	// a second write batch (and a second init.sh launch).
	wizardWriting
)

// wizardClosedMsg tells the app to leave the wizard screen.
type wizardClosedMsg struct{ aborted bool }

// wizardWritesDoneMsg reports the env-set.sh write batch.
type wizardWritesDoneMsg struct{ err error }

// runWizardWrites is a seam (tests stub it); production writes through the
// single wizard write path with quiet runners — the TUI owns the terminal.
var runWizardWrites = func(root string, current, desired map[string]string) error {
	return wizard.WriteChanged(picexec.RunQuiet, picexec.RunQuietWithInput, root, current, desired)
}

var (
	wizardTitleStyle  = lipgloss.NewStyle().Bold(true).Padding(0, 1)
	wizardFooterStyle = lipgloss.NewStyle().Faint(true).Padding(0, 1)
)

type wizardScreen struct {
	root        string
	reconfigure bool

	wf      *wizard.Form
	phase   wizardPhase
	current map[string]string // pre-wizard values: the changed-keys baseline

	width, height int
}

// newWizardScreen seeds the form. Fresh setup: .env.example defaults.
// Reconfigure: example defaults with the current .env merged over them —
// env-set.sh materializes a full .env from the example, so a script-created
// .env is never sparse, but a hand-edited one can be; merging means missing
// keys present as their defaults instead of empty fields, and the merged map
// is the changed-keys baseline so accepting those defaults writes nothing.
func newWizardScreen(root string, reconfigure bool) (*wizardScreen, error) {
	current, err := wizard.ReadEnvValues(filepath.Join(root, ".env.example"))
	if err != nil {
		return nil, err
	}
	if reconfigure {
		env, err := wizard.ReadEnvValues(filepath.Join(root, ".env"))
		if err != nil {
			return nil, err
		}
		for k, v := range env {
			current[k] = v
		}
	}
	return &wizardScreen{
		root:        root,
		reconfigure: reconfigure,
		wf:          wizard.NewForm(current, false),
		current:     current,
	}, nil
}

func (s *wizardScreen) init() tea.Cmd { return s.wf.Main.Init() }

// setSize sizes the forms on resize (and before init — the app sizes the
// screen before pumping it).
func (s *wizardScreen) setSize(width, height int) {
	s.width, s.height = width, height
	s.wf.Main = s.applySize(s.wf.Main)
	if s.wf.Confirm != nil {
		s.wf.Confirm = s.applySize(s.wf.Confirm)
	}
}

// applySize feeds the form the synthetic resize huh expects — the same code
// path its standalone host exercises. huh recomputes group viewport heights
// ONLY in its WindowSizeMsg handler, and only while no explicit WithWidth
// was ever set: WithWidth freezes group viewports at their construction-time
// width-80 measurement, so any field whose description wraps taller at the
// real width gets its input line clipped below the viewport fold (typed
// text recorded but invisible). Never call WithWidth on these forms.
func (s *wizardScreen) applySize(f *huh.Form) *huh.Form {
	m, _ := f.Update(tea.WindowSizeMsg{Width: s.formWidth(), Height: s.formHeight()})
	if ff, ok := m.(*huh.Form); ok {
		return ff
	}
	return f
}

func (s *wizardScreen) formWidth() int {
	return max(min(s.width-4, 76), 40)
}

// formHeight is the vertical budget huh may content-fit within (it caps
// group heights at min(needed, this)).
func (s *wizardScreen) formHeight() int {
	if s.height <= 0 {
		return 40 // unsized yet: don't constrain content
	}
	return max(s.height-4, 8)
}

func (s *wizardScreen) update(msg tea.Msg) (*wizardScreen, tea.Cmd) {
	// The footer promises "esc cancel", but huh ships its esc binding
	// disabled (only ctrl+c aborts a form). Intercept esc here, like the
	// activity screen does, so the advertised key actually works. Not in
	// wizardWriting: writes in flight are not cancellable.
	if key, ok := msg.(tea.KeyMsg); ok && key.String() == "esc" && s.phase != wizardWriting {
		return s, closeWizard(true)
	}

	switch s.phase {
	case wizardMain:
		form, cmd := s.wf.Main.Update(msg)
		if f, ok := form.(*huh.Form); ok {
			s.wf.Main = f
		}
		switch s.wf.Main.State {
		case huh.StateAborted:
			return s, closeWizard(true)
		case huh.StateCompleted:
			s.phase = wizardConfirm
			s.wf.Confirm = s.applySize(s.wf.BuildConfirm())
			return s, s.wf.Confirm.Init()
		}
		return s, cmd

	case wizardConfirm:
		form, cmd := s.wf.Confirm.Update(msg)
		if f, ok := form.(*huh.Form); ok {
			s.wf.Confirm = f
		}
		switch s.wf.Confirm.State {
		case huh.StateAborted:
			return s, closeWizard(true)
		case huh.StateCompleted:
			if !s.wf.Confirmed() {
				return s, closeWizard(true)
			}
			// Terminal transition BEFORE issuing the cmd — see wizardWriting.
			s.phase = wizardWriting
			return s, s.writeCmd()
		}
		return s, cmd

	default: // wizardWriting — writes in flight; swallow everything
		return s, nil
	}
}

func closeWizard(aborted bool) tea.Cmd {
	return func() tea.Msg { return wizardClosedMsg{aborted: aborted} }
}

func (s *wizardScreen) writeCmd() tea.Cmd {
	root, current, desired := s.root, s.current, s.wf.Desired()
	return func() tea.Msg {
		return wizardWritesDoneMsg{err: runWizardWrites(root, current, desired)}
	}
}

func (s *wizardScreen) view() string {
	title := "Set up PIC-SURE"
	if s.reconfigure {
		title = "Reconfigure PIC-SURE"
	}

	var body, footer string
	switch s.phase {
	case wizardWriting:
		body = "writing configuration…"
		footer = ""
	case wizardConfirm:
		body = s.wf.Confirm.View()
		footer = wizardFooterStyle.Render("esc cancel")
	default:
		body = s.wf.Main.View()
		footer = wizardFooterStyle.Render("esc cancel")
	}

	content := lipgloss.JoinVertical(lipgloss.Left,
		wizardTitleStyle.Render(title), body, footer)
	if s.width == 0 || s.height == 0 {
		return content
	}
	return lipgloss.Place(s.width, s.height, lipgloss.Center, lipgloss.Center, content)
}
