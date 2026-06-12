package dashboard

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/dialog"
)

// startConfirm opens a huh dialog for an action. Destructive actions
// require typing the action name; everything else is a yes/no confirm.
func (m *model) startConfirm(act actions.Action) (tea.Model, tea.Cmd) {
	m.pending = &act
	m.confirmOK = false
	m.confirmText = ""

	var field huh.Field
	if act.Destructive {
		word := act.ConfirmWord
		field = huh.NewInput().
			Title(fmt.Sprintf("⚠ %s — this destroys data", act.Name)).
			Description(act.Describe + fmt.Sprintf("\n\nType %q to confirm (esc cancels):", word)).
			Value(&m.confirmText).
			Validate(func(s string) error {
				if s != word {
					return fmt.Errorf("type %q exactly to confirm", word)
				}
				return nil
			})
	} else {
		field = huh.NewConfirm().
			Title(fmt.Sprintf("Run %s?", m.pending.Name)).
			Description(act.Describe).
			Affirmative("Run").
			Negative("Cancel").
			Value(&m.confirmOK)
	}

	m.form = m.sizeForm(huh.NewForm(huh.NewGroup(field)).WithShowHelp(true))
	m.mode = modeConfirm
	return m, m.form.Init()
}

// sizeForm feeds a dialog form the synthetic resize huh expects, sized to the
// FORM PANE it renders in (m.width-leftWidth()-8), not the whole terminal. Using
// WithWidth, or sizing to the terminal, lays the form out wider than the pane
// so lipgloss re-wraps every line inside it, mangling titles/descriptions
// below 120 cols. As with landing.sizeForm: no WithWidth, so huh recomputes
// group viewport heights on every WindowSizeMsg (WithWidth would freeze them).
func (m *model) sizeForm(f *huh.Form) *huh.Form {
	_, cols := m.actionPaneSize() // form-pane content width = m.width-leftWidth()-8
	// -5 = the frame's chrome rows around the form pane content: header (1) +
	// pane border top/bottom (2) + footer help line (1), plus 1 row of slack
	// so the composed frame can never exceed the terminal box.
	height := max(m.height-5, 8)
	mm, _ := f.Update(tea.WindowSizeMsg{Width: cols, Height: height})
	if ff, ok := mm.(*huh.Form); ok {
		return ff
	}
	return f
}

// startPicker opens the demo-data dataset picker (the only parameterless ETL
// entry points; everything else needs file paths — use the CLI for those).
// The picker IS the consent (spec consent model: pickers carry a Cancel row
// and dispatch on selection — no second confirm), so the description carries
// the REPLACES warning itself.
func (m *model) startPicker() (tea.Model, tea.Cmd) {
	// Preselect the default dataset, and bind Value BEFORE Options: huh
	// computes the option viewport's scroll offset when Options() runs, from
	// the accessor's CURRENT value — an empty accessor matches the Cancel
	// option ("") and opens the picker scrolled to the bottom with the
	// cursor out of sight.
	m.pickedDataset = "nhanes"
	m.form = m.sizeForm(huh.NewForm(huh.NewGroup(
		huh.NewSelect[string]().
			Title("Load demo data").
			Description("REPLACES the phenotype data in the hpds-data volume with the\nselected dataset, then re-hydrates the dictionary database.").
			Value(&m.pickedDataset).
			Options(
				huh.NewOption("NHANES (default demo dataset)", "nhanes"),
				huh.NewOption("Synthea 10k", "synthea"),
				huh.NewOption("1000 Genomes", "1000genomes"),
				huh.NewOption("All three combined", "all"),
				huh.NewOption("Cancel", ""),
			),
	)))
	m.mode = modePick
	return m, m.form.Init()
}

// startReset opens the combined reset dialog (scope keep/all + repos toggle +
// typed-word confirm), the same form the landing screen uses — built by
// dialog.ResetForm and sized here to the dashboard's form pane.
func (m *model) startReset() (tea.Model, tea.Cmd) {
	m.resetScope = "keep"
	m.resetRepos = false
	m.confirmText = ""
	word := actions.Reset().ConfirmWord

	m.form = m.sizeForm(dialog.ResetForm(&m.resetScope, &m.resetRepos, &m.confirmText, word))
	m.mode = modeReset
	return m, m.form.Init()
}

func (m *model) updateForm(msg tea.Msg) (tea.Model, tea.Cmd) {
	form, cmd := m.form.Update(msg)
	if f, ok := form.(*huh.Form); ok {
		m.form = f
	}

	switch m.form.State {
	case huh.StateCompleted:
		switch m.mode {
		case modePick:
			// The picker is the consent: dispatch on selection, no second
			// confirm (spec consent model — Cancel is the empty option).
			choice := m.pickedDataset
			m.form = nil
			if choice == "" {
				m.mode = modeNormal
				return m, nil
			}
			return m.startAction(actions.DemoData(choice))
		case modeReset:
			act := actions.ResetWith(m.resetScope == "all", m.resetRepos)
			m.form = nil
			// Re-validate the typed word at the dispatch seam (defense in
			// depth: the form's own Validate already gates real input).
			if !actions.ConfirmAccepted(act, false, m.confirmText) {
				m.mode = modeNormal
				return m, nil
			}
			return m.startAction(act)
		case modeConfirm:
			act := m.pending
			m.form = nil
			if !actions.ConfirmAccepted(*act, m.confirmOK, m.confirmText) {
				m.mode = modeNormal
				return m, nil
			}
			return m.startAction(*act)
		}
	case huh.StateAborted:
		m.form = nil
		m.mode = modeNormal
		return m, nil
	}
	return m, cmd
}

func (m *model) startAction(act actions.Action) (tea.Model, tea.Cmd) {
	rows, cols := m.actionPaneSize()
	runner, err := startPTY(m.root, act, rows, cols)
	if err != nil {
		m.lastResult = fmt.Sprintf("%s failed to start: %v", act.Name, err)
		m.mode = modeNormal
		return m, nil
	}
	m.runner = runner
	m.actionName = act.Name
	m.actionAbortNote = act.AbortNote
	m.actionOut = actions.NewOutputBuffer()
	m.actionView.SetContent("")
	m.mode = modeActing
	// Fresh run: bump the sequence so any grace timer armed by a previous
	// run's abort is discarded as stale, and clear leftover abort state.
	m.actionSeq++
	m.confirmingAbort, m.aborted, m.killOffered, m.lastAborted = false, false, false, false
	return m, runner.WaitData()
}
