package dashboard

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
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

	m.form = huh.NewForm(huh.NewGroup(field)).
		WithWidth(min(m.width-4, 76)).
		WithShowHelp(true)
	m.mode = modeConfirm
	return m, m.form.Init()
}

// startPicker opens the ETL dataset picker (the only parameterless ETL
// entry points; everything else needs file paths — use the CLI for those).
func (m *model) startPicker() (tea.Model, tea.Cmd) {
	// Preselect the default dataset, and bind Value BEFORE Options: huh
	// computes the option viewport's scroll offset when Options() runs, from
	// the accessor's CURRENT value — an empty accessor matches the Cancel
	// option ("") and opens the picker scrolled to the bottom with the
	// cursor out of sight.
	m.pickedDataset = "nhanes"
	m.form = huh.NewForm(huh.NewGroup(
		huh.NewSelect[string]().
			Title("Load demo data").
			Description("Replaces current HPDS phenotype data; other ETL operations\n(load-csv, load-vcf, ...) take file arguments — use `pic-sure etl`.").
			Value(&m.pickedDataset).
			Options(
				huh.NewOption("NHANES (default demo dataset)", "nhanes"),
				huh.NewOption("Synthea 10k", "synthea"),
				huh.NewOption("1000 Genomes", "1000genomes"),
				huh.NewOption("All three combined", "all"),
				huh.NewOption("Cancel", ""),
			),
	)).WithWidth(min(m.width-4, 76))
	m.mode = modePick
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
			if m.pickedDataset == "" {
				m.mode = modeNormal
				return m, nil
			}
			return m.startConfirm(actions.DemoData(m.pickedDataset))
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
	runner, err := actions.StartPTY(m.root, act, rows, cols)
	if err != nil {
		m.lastResult = fmt.Sprintf("%s failed to start: %v", act.Name, err)
		m.mode = modeNormal
		return m, nil
	}
	m.runner = runner
	m.actionName = act.Name
	m.actionOut = actions.NewOutputBuffer()
	m.actionView.SetContent("")
	m.mode = modeActing
	return m, runner.WaitData()
}
