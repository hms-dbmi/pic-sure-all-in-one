package tui

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/contract"
	picexec "github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/exec"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"
)

// Navigation/action requests the landing emits; the app routes them.
type openDashboardMsg struct{}
type runActionMsg struct{ act actions.Action }

var (
	landingBoxStyle    = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(1, 4)
	landingFooterStyle = lipgloss.NewStyle().Faint(true)
	landingResultStyle = lipgloss.NewStyle().Bold(true)
)

// fetchReleaseBranch reads the current release-control branch for the
// switch-branch prefill (read-only; status.sh --json is the contract).
// NOTE: synchronous and not cheap (~1s — status.sh forks git per repo); fine
// for this one-shot dev-submenu path, but do not copy onto a hot path.
var fetchReleaseBranch = func(root string) string {
	code, out, err := picexec.RunOutput(root, scripts.Status, []string{"--json"})
	if err != nil || code != 0 {
		return ""
	}
	st, err := contract.ParseStatus([]byte(out))
	if err != nil {
		return ""
	}
	return st.ReleaseControl.Branch
}

// landing is the starfield + logo + menu home screen. Menu growth rule
// (spec, Constraints): an entry collects at most one input and maps 1:1 to a
// script invocation already exposed by the CLI.
type landing struct {
	root       string
	envExists  bool
	animations bool

	star   *starfield
	logo   *logo
	menu   *menu
	dev    bool // in the developer-options submenu
	relctl bool // in the release-control submenu (nested under dev)

	form        *huh.Form
	confirmOK   bool
	confirmText string
	pending     *actions.Action
	resetting   bool                        // true while the combined reset dialog is open
	resetScope  string                      // "keep" or "all" — set only while resetting is true
	picked      string                      // picker selection value
	pickerMake  func(string) actions.Action // non-nil while a picker is open
	inputVal    string                      // text-input value
	inputMake   func(string) actions.Action // non-nil while a text-input is open

	result        string
	width, height int
}

func newLanding(root string, envExists, animations bool) *landing {
	l := &landing{
		root:       root,
		envExists:  envExists,
		animations: animations,
		star:       newStarfield(starGlyphs(os.Getenv)),
		logo:       newLogo(),
	}
	l.rebuildMenu()
	return l
}

func (l *landing) rebuildMenu() {
	switch {
	case l.relctl:
		l.menu = newMenu(
			menuItem{ID: "rcapply", Label: "Re-apply current branch"},
			menuItem{ID: "rcdryrun", Label: "Dry run"},
			menuItem{ID: "rcbranch", Label: "Switch branch…"},
			menuItem{ID: "back", Label: "Back"},
		)
	case l.dev:
		l.menu = newMenu(
			menuItem{ID: "migrate", Label: "Run migrations"},
			menuItem{ID: "seed", Label: "Seed database"},
			menuItem{ID: "etl", Label: "ETL operations…"},
			menuItem{ID: "devoverlay", Label: "Apply dev overlay…"},
			menuItem{ID: "devrevert", Label: "Revert dev overlay…"},
			menuItem{ID: "relctl", Label: "Release control…"},
			menuItem{ID: "reset", Label: "Reset…"},
			menuItem{ID: "uninstall", Label: "Uninstall…"},
			menuItem{ID: "back", Label: "Back"},
		)
	case l.envExists:
		l.menu = newMenu(
			menuItem{ID: "dashboard", Label: "Dashboard"},
			menuItem{ID: "update", Label: "Update"},
			menuItem{ID: "demo", Label: "Load demo data"},
			menuItem{ID: "preflight", Label: "Preflight check"},
			menuItem{ID: "reconfigure", Label: "Reconfigure"},
			menuItem{ID: "devmenu", Label: "Developer options…"},
			menuItem{ID: "quit", Label: "Quit"},
		)
	default:
		l.menu = newMenu(
			menuItem{ID: "setup", Label: "Set up PIC-SURE"},
			menuItem{ID: "preflight", Label: "Preflight check"},
			menuItem{ID: "quit", Label: "Quit"},
		)
	}
}

// startAnimations (re)starts the starfield/logo chains; no-op chains when the
// kill switch is on (static frame still renders).
func (l *landing) startAnimations() tea.Cmd {
	if !l.animations {
		return nil
	}
	return tea.Batch(l.star.startTicks(), l.logo.startShine(true))
}

// stopAnimations halts both the starfield and logo animation chains.
func (l *landing) stopAnimations() {
	l.star.stopTicks()
	l.logo.stopShine()
}

// setEnvExists refreshes context-awareness (called after setup or actions).
func (l *landing) setEnvExists(exists bool) {
	if l.envExists == exists {
		return
	}
	l.envExists = exists
	l.dev = false
	l.relctl = false
	l.rebuildMenu()
}

func (l *landing) setSize(width, height int) {
	l.width, l.height = width, height
	l.star.resize(width, height)
}

func (l *landing) update(msg tea.Msg) (*landing, tea.Cmd) {
	// Animation ticks MUST be handled before the form gate: tick chains only
	// continue when each tick is rescheduled, so letting an open confirm
	// swallow one would freeze the starfield permanently.
	switch msg := msg.(type) {
	case starTickMsg:
		return l, l.star.update(msg)
	case logoShineStartMsg, logoShineStepMsg:
		return l, l.logo.update(msg)
	}

	// Confirm dialog consumes everything else while open.
	if l.form != nil {
		return l.updateForm(msg)
	}

	if key, ok := msg.(tea.KeyMsg); ok {
		return l.handleKey(key)
	}
	return l, nil
}

func (l *landing) handleKey(msg tea.KeyMsg) (*landing, tea.Cmd) {
	switch msg.String() {
	case "q", "ctrl+c":
		return l, tea.Quit
	case "up", "k":
		l.menu.move(-1)
	case "down", "j":
		l.menu.move(1)
	case "esc":
		if l.relctl {
			l.relctl = false
			l.rebuildMenu()
		} else if l.dev {
			l.dev = false
			l.rebuildMenu()
		}
	case "enter":
		return l.choose(l.menu.selectedItem().ID)
	}
	return l, nil
}

func (l *landing) choose(id string) (*landing, tea.Cmd) {
	l.result = "" // any navigation retires the last setup-result line
	switch id {
	case "quit":
		return l, tea.Quit
	case "back":
		if l.relctl {
			l.relctl = false
		} else {
			l.dev = false
		}
		l.rebuildMenu()
		return l, nil
	case "devmenu":
		l.dev = true
		l.rebuildMenu()
		return l, nil
	case "dashboard":
		return l, func() tea.Msg { return openDashboardMsg{} }
	case "setup":
		return l, func() tea.Msg { return openWizardMsg{} }
	case "reconfigure":
		return l, func() tea.Msg { return openWizardMsg{reconfigure: true} }
	case "preflight":
		// Read-only: runs immediately, no confirm (spec: Flows table).
		act := actions.Preflight()
		return l, func() tea.Msg { return runActionMsg{act: act} }
	case "update":
		return l.startConfirm(actions.Update())
	case "demo":
		return l.startSelectPicker("Load demo data",
			"REPLACES the phenotype data in the hpds-data volume with the\nselected dataset, then re-hydrates the dictionary database.",
			"nhanes",
			[]huh.Option[string]{
				huh.NewOption("NHANES (default demo dataset)", "nhanes"),
				huh.NewOption("Synthea 10k", "synthea"),
				huh.NewOption("1000 Genomes", "1000genomes"),
				huh.NewOption("All three combined", "all"),
				huh.NewOption("Cancel", ""),
			},
			actions.DemoData)
	case "migrate":
		return l.startConfirm(actions.Migrate())
	case "seed":
		return l.startConfirm(actions.SeedDB())
	case "etl":
		return l.startSelectPicker("ETL operations",
			"Parameterless etl.sh steps; subcommands that take file arguments\n(load-csv, load-vcf, ...) are CLI-only — see `pic-sure etl --help`.",
			"hydrate-dictionary",
			[]huh.Option[string]{
				huh.NewOption("hydrate-dictionary", "hydrate-dictionary"),
				huh.NewOption("run-weights", "run-weights"),
				huh.NewOption("promote-genomic", "promote-genomic"),
				huh.NewOption("public-1000genomes (large download)", "public-1000genomes"),
				huh.NewOption("Cancel", ""),
			},
			actions.Etl)
	case "devoverlay":
		return l.startDevPicker("Apply dev overlay",
			"Recreates the overlay's service from local source (one-shot:\na later plain up or update reverts it to the release image).",
			actions.DevUp)
	case "devrevert":
		return l.startDevPicker("Revert service to release",
			"Recreates the selected overlay's service from the release image\n(base compose files only).",
			actions.DevOff)
	case "relctl":
		l.relctl = true
		l.rebuildMenu()
		return l, nil
	case "rcapply":
		return l.startConfirm(actions.ReleaseControlApply())
	case "rcdryrun":
		return l.startConfirm(actions.ReleaseControlDryRun())
	case "rcbranch":
		return l.startBranchInput()
	case "reset":
		return l.startResetConfirm()
	case "uninstall":
		return l.startConfirm(actions.Uninstall())
	}
	return l, nil
}

// sizeForm feeds a landing dialog form the synthetic resize huh expects.
// As with the wizard screen: huh recomputes group viewport heights only in
// its WindowSizeMsg handler and only while no explicit WithWidth was set —
// WithWidth freezes the viewport at the construction-time width-80
// measurement, clipping options/fields whose content wraps taller at the
// real width (the dev picker opened showing only its Cancel row).
func (l *landing) sizeForm(f *huh.Form) *huh.Form {
	width := max(min(l.width-4, 76), 40) // floor: l.width is 0 pre-resize
	height := 40
	if l.height > 0 {
		height = max(l.height-4, 8)
	}
	m, _ := f.Update(tea.WindowSizeMsg{Width: width, Height: height})
	if ff, ok := m.(*huh.Form); ok {
		return ff
	}
	return f
}

// devOverlays lists the available dev compose overlay names. Only the
// NAMES come from Go (a file-listing convenience for the picker); what an
// overlay means — file selection, service resolution, compose invocation —
// lives entirely in scripts/compose.sh.
func devOverlays(root string) []string {
	matches, err := filepath.Glob(filepath.Join(root, "docker-compose.dev-*.yml"))
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(matches))
	for _, m := range matches {
		base := strings.TrimSuffix(filepath.Base(m), ".yml")
		names = append(names, strings.TrimPrefix(base, "docker-compose.dev-"))
	}
	sort.Strings(names)
	return names
}

// startSelectPicker opens a single-select dialog; the selection is the
// consent (menu growth rule: one input, mapping 1:1 to a CLI-exposed script
// invocation). Remember the huh gotcha: Value is bound BEFORE Options.
func (l *landing) startSelectPicker(title, description, preselect string, opts []huh.Option[string], makeAction func(string) actions.Action) (*landing, tea.Cmd) {
	l.picked = preselect
	l.pickerMake = makeAction
	l.form = l.sizeForm(huh.NewForm(huh.NewGroup(
		huh.NewSelect[string]().
			Title(title).
			Description(description).
			Value(&l.picked).
			Options(opts...),
	)))
	return l, l.form.Init()
}

// startDevPicker opens an overlay picker; the selection is the consent (like
// the demo-data picker) and maps 1:1 to a scripts/compose.sh dev invocation.
func (l *landing) startDevPicker(title, description string, makeAction func(string) actions.Action) (*landing, tea.Cmd) {
	overlays := devOverlays(l.root)
	if len(overlays) == 0 {
		l.result = "no docker-compose.dev-*.yml overlays found in this checkout"
		return l, nil
	}
	opts := make([]huh.Option[string], 0, len(overlays)+1)
	for _, o := range overlays {
		opts = append(opts, huh.NewOption(o, o))
	}
	opts = append(opts, huh.NewOption("Cancel", ""))

	// Delegate to startSelectPicker; pre-selects the first overlay so the
	// cursor is not pinned to the Cancel row on open.
	return l.startSelectPicker(title, description, overlays[0], opts, makeAction)
}

// startBranchInput is the one-field release-control branch input (the menu
// growth rule's ceiling: one input, prefilled, mapping 1:1 to
// release-control.sh --branch).
func (l *landing) startBranchInput() (*landing, tea.Cmd) {
	l.inputVal = fetchReleaseBranch(l.root)
	l.inputMake = actions.ReleaseControlBranch
	l.form = l.sizeForm(huh.NewForm(huh.NewGroup(
		huh.NewInput().
			Title("Switch release-control branch").
			Description("Switches, resolves, and applies the branch's refs\n(empty input cancels; esc cancels).").
			Value(&l.inputVal),
	)))
	return l, l.form.Init()
}

// startConfirm mirrors the dashboard's dialog semantics: destructive actions
// require typing the action name; everything else is a light yes/no.
func (l *landing) startConfirm(act actions.Action) (*landing, tea.Cmd) {
	l.pending = &act
	l.confirmOK = false
	l.confirmText = ""

	var field huh.Field
	if act.Destructive {
		word := act.ConfirmWord
		field = huh.NewInput().
			Title(fmt.Sprintf("⚠ %s — this destroys data", act.Name)).
			Description(act.Describe + fmt.Sprintf("\n\nType %q to confirm (esc cancels):", word)).
			Value(&l.confirmText).
			Validate(func(s string) error {
				if s != word {
					return fmt.Errorf("type %q exactly to confirm", word)
				}
				return nil
			})
	} else {
		field = huh.NewConfirm().
			Title(fmt.Sprintf("Run %s?", act.Name)).
			Description(act.Describe).
			Affirmative("Run").
			Negative("Cancel").
			Value(&l.confirmOK)
	}

	l.form = l.sizeForm(huh.NewForm(huh.NewGroup(field)).WithShowHelp(true))
	return l, l.form.Init()
}

// resetAction maps the combined reset dialog's scope choice to the script
// invocation: "all" → reset.sh --all (full wipe), anything else → the
// DB-preserving reset.
func resetAction(scope string) actions.Action {
	if scope == "all" {
		return actions.ResetAll()
	}
	return actions.Reset()
}

// startResetConfirm opens ONE screen that carries both the scope choice
// (keep the database vs. full wipe) and the typed-word confirm, so the two
// reset variants share a single dialog instead of two menu items. The scope
// select must bind Value BEFORE Options (huh gotcha) and preselect a real
// option so the cursor is not pinned to an empty row.
func (l *landing) startResetConfirm() (*landing, tea.Cmd) {
	l.resetting = true
	l.resetScope = "keep"
	l.confirmText = ""
	word := actions.Reset().ConfirmWord

	scope := huh.NewSelect[string]().
		Title("⚠ Reset — this destroys data").
		Description("Stops all containers and removes generated state so you can re-init:\n"+
			"  • .env (backed up first), certs/, .data/, generated config, deployed WARs\n"+
			"Sibling repos and .env.example are kept. Choose how much to wipe:").
		Value(&l.resetScope).
		Options(
			huh.NewOption("Keep the database — picsure-db data preserved; re-init reuses it", "keep"),
			huh.NewOption("Full wipe — also drop the DB volume, PIC-SURE images, and the Maven cache", "all"),
		)

	confirm := huh.NewInput().
		Title(fmt.Sprintf("Type %q to confirm", word)).
		Description("(esc cancels)").
		Value(&l.confirmText).
		Validate(func(s string) error {
			if s != word {
				return fmt.Errorf("type %q exactly to confirm", word)
			}
			return nil
		})

	l.form = l.sizeForm(huh.NewForm(huh.NewGroup(scope, confirm)).WithShowHelp(true))
	return l, l.form.Init()
}

func (l *landing) updateForm(msg tea.Msg) (*landing, tea.Cmd) {
	// huh ships its esc binding disabled (only ctrl+c aborts a form), but
	// every dialog here advertises "esc cancels" — intercept it, exactly as
	// the wizard screen does. One chokepoint covers all four dialog kinds.
	if key, ok := msg.(tea.KeyMsg); ok && key.String() == "esc" {
		l.form, l.pending, l.pickerMake, l.inputMake = nil, nil, nil, nil
		l.resetting, l.resetScope = false, ""
		return l, nil
	}

	form, cmd := l.form.Update(msg)
	if f, ok := form.(*huh.Form); ok {
		l.form = f
	}
	switch l.form.State {
	case huh.StateCompleted:
		if l.resetting {
			act := resetAction(l.resetScope)
			l.form, l.resetting, l.resetScope = nil, false, ""
			// Re-validate the typed word at the dispatch seam (defense in
			// depth: the form's own Validate already gates real input).
			if !actions.ConfirmAccepted(act, false, l.confirmText) {
				return l, nil
			}
			return l, func() tea.Msg { return runActionMsg{act: act} }
		}
		if l.inputMake != nil {
			makeAction, val := l.inputMake, strings.TrimSpace(l.inputVal)
			l.form, l.inputMake = nil, nil
			if val == "" {
				return l, nil
			}
			a := makeAction(val)
			return l, func() tea.Msg { return runActionMsg{act: a} }
		}
		if l.pickerMake != nil {
			makeAction, choice := l.pickerMake, l.picked
			l.form, l.pickerMake = nil, nil
			if choice == "" {
				return l, nil // Cancel
			}
			a := makeAction(choice)
			return l, func() tea.Msg { return runActionMsg{act: a} }
		}
		act := l.pending
		l.form, l.pending = nil, nil
		if !actions.ConfirmAccepted(*act, l.confirmOK, l.confirmText) {
			return l, nil
		}
		a := *act
		return l, func() tea.Msg { return runActionMsg{act: a} }
	case huh.StateAborted:
		l.form, l.pending, l.pickerMake, l.inputMake = nil, nil, nil, nil
		l.resetting, l.resetScope = false, ""
		return l, nil
	}
	return l, cmd
}

// view composites the content block over the starfield: full starfield rows
// above/below, starfield margins beside each content row. When the content
// is taller than the terminal, the logo is dropped first so a confirm form
// is never cut off below the fold.
func (l *landing) view() string {
	if l.width < 20 || l.height < 10 {
		return "PIC-SURE\n(terminal too small)"
	}
	l.star.computeGrid()

	content := l.contentLines(true)
	if len(content) > l.height {
		content = l.contentLines(false)
	}
	return l.composite(content)
}

func (l *landing) contentLines(withLogo bool) []string {
	var content []string
	switch {
	case !withLogo:
		// nothing — body starts immediately
	case logoWidth()+4 <= l.width:
		content = append(content, strings.Split(l.logo.view(), "\n")...)
		content = append(content, "")
	default:
		content = append(content, lipgloss.NewStyle().Bold(true).Render("P I C - S U R E"), "")
	}

	if l.form != nil {
		content = append(content, strings.Split(l.form.View(), "\n")...)
	} else {
		menuWidth := min(max(l.width/3, 28), l.width-8)
		box := landingBoxStyle.Render(l.menu.view(menuWidth))
		content = append(content, strings.Split(box, "\n")...)
	}
	if l.result != "" {
		content = append(content, "", landingResultStyle.Render(l.result))
	}
	content = append(content, "", landingFooterStyle.Render(l.footer()))
	return content
}

func (l *landing) footer() string {
	if l.dev || l.relctl {
		return "↑/↓ select · enter · esc back · q quit"
	}
	return "↑/↓ select · enter · q quit"
}

func (l *landing) composite(content []string) string {
	top := max((l.height-len(content))/2, 0)
	rows := make([]string, 0, l.height)
	for row := 0; row < l.height; row++ {
		ci := row - top
		if ci < 0 || ci >= len(content) {
			rows = append(rows, l.star.renderRow(row, 0, l.width))
			continue
		}
		line := content[ci]
		lw := lipgloss.Width(line)
		left := max((l.width-lw)/2, 0)
		rows = append(rows,
			l.star.renderRow(row, 0, left)+line+l.star.renderRow(row, left+lw, l.width))
	}
	return strings.Join(rows, "\n")
}
