package tui

import (
	"errors"
	"fmt"
	"regexp"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	picexec "github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/exec"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/filebrowser"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/styles"
)

// The "Load your data" guided screen (Phases LD-4/LD-5). A self-contained,
// app-shell routed tea.Model (ScreenLoadData) that walks the user through
// loading either a phenotype CSV or a genomic VCF partition and dispatches one
// actions.LoadPhenotype / actions.LoadGenomic run into the activity screen.
//
// Step state machine (loadStep):
//
//	loadKind ──phenotype──▶ loadPhenoFile ─▶ loadPhenoHeap ─▶ loadPhenoDict
//	   │ genomic                  │ (≥2 CSVs in archive)            │
//	   │                          ▼                                 │
//	   │                 loadPhenoArchiveEntry ─▶ loadPhenoHeap     │
//	   │                                               auto ──────┤
//	   │                                     custom ─▶ loadPhenoDatasets
//	   │                                              ─▶ loadPhenoConcepts
//	   │                                              ─▶ loadPhenoFacetsAsk
//	   │                                     no ───────────────┐ │ yes
//	   │                                                       │ ▼
//	   │                                     loadPhenoFacetCategories
//	   │                                             ─▶ loadPhenoFacets
//	   │                                             ─▶ loadPhenoFacetConcepts
//	   │                                                       │
//	   │                                                       ▼
//	   │                                                  loadConfirm ─▶ dispatch
//	   │
//	   ▼ genomic
//	loadGenomicIndex ─▶ loadGenomicDirAsk ──no──▶ loadGenomicPartition
//	                          │ yes                        │
//	                          ▼                            ▼
//	                    loadGenomicDir ─────────▶ loadGenomicHeap
//	                                                       │
//	                                                       ▼
//	                            loadGenomicPromote ─▶ loadGenomicProfile
//	                                                       │
//	                                                       ▼
//	                                            loadGenomicConfirm ─▶ dispatch
//	   │ cancel
//	   ▼
//	close
type loadStep int

const (
	loadKind loadStep = iota
	loadPhenoFile
	loadPhenoArchiveEntry
	loadPhenoHeap
	loadPhenoDict
	loadPhenoDatasets
	loadPhenoConcepts
	loadPhenoFacetsAsk
	loadPhenoFacetCategories
	loadPhenoFacets
	loadPhenoFacetConcepts
	loadConfirm

	// Genomic branch (LD-5).
	loadGenomicIndex
	loadGenomicDirAsk
	loadGenomicDir
	loadGenomicPartition
	loadGenomicHeap
	loadGenomicPromote
	loadGenomicProfile
	loadGenomicConfirm
)

// defaultHeap is the JVM heap (MB) the phenotype heap input opens prefilled
// with — the recommended floor for the common <1M-row phenotype CSV.
const defaultHeap = "4096"

// defaultGenomicHeap is the JVM heap (MB) the genomic heap input opens
// prefilled with — genomic loads need substantially more headroom than the
// phenotype floor.
const defaultGenomicHeap = "16000"

// fetchArchiveCSVs lists the *.csv entries of a compressed/archived phenotype
// file via the read-only `etl.sh archive-csvs <file>` lister (LD-7a contract):
// it prints the tar entries one per line (LC_ALL=C sorted), prints nothing for
// a raw .csv or a plain .gz, and exits non-zero on a missing/unreadable file.
// A package var so tests inject entries without forking etl.sh, mirroring
// landing.go's fetchDevOverlays. It MUST run inside a tea.Cmd (never in Update)
// because it forks a bash process.
var fetchArchiveCSVs = func(root, file string) ([]string, error) {
	code, out, err := picexec.RunOutput(root, scripts.Etl, []string{"archive-csvs", file})
	if err != nil {
		return nil, err
	}
	if code != 0 {
		return nil, fmt.Errorf("archive-csvs exited %d", code)
	}
	var entries []string
	for _, line := range strings.Split(out, "\n") {
		// archive-csvs already sorts and emits exact entry paths; trim only the
		// trailing newline framing, never the entry text (a subdir prefix is
		// significant and must be passed to --entry verbatim).
		if line = strings.TrimRight(line, "\r"); line != "" {
			entries = append(entries, line)
		}
	}
	return entries, nil
}

// archiveCSVsFillMsg carries the result of the async `etl.sh archive-csvs` call
// off the update hot-path. seq stamps the loadPhenoFile selection it was fetched
// for, so a result that arrives after the file step was re-entered or the screen
// closed cannot land in the wrong place (mirrors devOverlaysFillMsg).
type archiveCSVsFillMsg struct {
	seq     int
	entries []string
	err     error
}

// openLoadDataMsg asks the app to open the guided load screen.
type openLoadDataMsg struct{}

// loadDataClosedMsg tells the app to leave the load screen (aborted=true when
// the user cancelled, mirroring wizardClosedMsg's neutral-result behavior).
type loadDataClosedMsg struct{ aborted bool }

var (
	loadTitleStyle  = lipgloss.NewStyle().Bold(true).Foreground(styles.Brand).Padding(0, 1)
	loadFooterStyle = lipgloss.NewStyle().Faint(true).Padding(0, 1)
)

type loadScreen struct {
	root string
	step loadStep

	// Exactly one of form / fb is live per step: huh forms drive the
	// select/input/confirm steps; fb drives the file steps. A file step builds
	// a FRESH filebrowser, so its Selected() poll can never observe a stale
	// selection carried over from a previous step (the "consume once, advance"
	// pattern — see consumeFile).
	form *huh.Form
	fb   filebrowser.Model

	// Collected values.
	kind            string // "phenotype" | "genomic" | "" (cancel)
	file            string
	archiveEntry    string // chosen CSV inside a multi-CSV archive (--entry); "" otherwise
	heap            string
	dictMode        string // "auto" | "custom"
	includeFacets   bool
	datasets        string
	concepts        string
	facetCategories string
	facets          string
	facetConcepts   string
	confirmed       bool

	// Genomic-branch collected values.
	vcfIndex      string
	includeVCFDir bool
	vcfDir        string
	partition     string
	promote       bool
	enableProfile bool

	// discarding raises the one-keystroke "Discard data load? (y/n)" confirm on
	// esc once any data has been collected, so a multi-step flow is not silently
	// thrown away by a reflexive esc. A pristine screen closes immediately.
	discarding bool

	// Archive-inspection state for the phenotype file step. When a non-plain-.csv
	// file is chosen, the screen runs `etl.sh archive-csvs` asynchronously to
	// learn whether the archive holds multiple CSVs (≥2 → entry picker). While the
	// call is in flight inspecting is true (the view shows a placeholder and the
	// filebrowser is parked); archiveSeq stamps each inspection so a stale result
	// for a since-re-entered/closed file step is dropped; archiveErr surfaces a
	// failed lookup inline so the user can re-pick.
	inspecting     bool
	archiveSeq     int
	archiveEntries []string
	archiveErr     string

	width, height int
}

func newLoadScreen(root string) *loadScreen {
	// kind is pre-set to "phenotype" (the first real option) so the huh select
	// cursor starts there on first paint. Without this, s.kind="" collides with
	// Cancel's value "" and huh preselects Cancel — the same gotcha fixed in the
	// dev-picker (landing.go startSelectPicker).
	s := &loadScreen{root: root, step: loadKind, heap: defaultHeap, dictMode: "auto", kind: "phenotype"}
	s.form = s.buildKindForm()
	return s
}

// init starts the kind-select form (the app sizes the screen first).
func (s *loadScreen) init() tea.Cmd { return s.form.Init() }

func (s *loadScreen) setSize(width, height int) {
	s.width, s.height = width, height
	if s.form != nil {
		s.form = s.sizeForm(s.form)
	}
	if isFileStep(s.step) {
		s.fb.SetSize(s.fbWidth(), s.fbHeight())
	}
}

// sizeForm feeds the active form the synthetic resize huh expects (same idiom
// as wizardScreen.applySize / landing.sizeForm: never call WithWidth, or huh
// freezes group viewports at the construction-time width-80 measurement and
// clips fields whose description wraps taller at the real width).
func (s *loadScreen) sizeForm(f *huh.Form) *huh.Form {
	m, _ := f.Update(tea.WindowSizeMsg{Width: s.formWidth(), Height: s.formHeight()})
	if ff, ok := m.(*huh.Form); ok {
		return ff
	}
	return f
}

func (s *loadScreen) formWidth() int { return max(min(s.width-4, 76), 40) }

func (s *loadScreen) formHeight() int {
	if s.height <= 0 {
		return 40 // unsized yet: don't constrain content
	}
	return max(s.height-4, 8)
}

func (s *loadScreen) fbWidth() int { return max(s.width-4, 20) }

func (s *loadScreen) fbHeight() int {
	if s.height <= 0 {
		return 20
	}
	return max(s.height-6, 5)
}

// isFileStep reports whether step is one of the filebrowser-driven steps.
func isFileStep(step loadStep) bool {
	switch step {
	case loadPhenoFile, loadPhenoDatasets, loadPhenoConcepts,
		loadPhenoFacetCategories, loadPhenoFacets, loadPhenoFacetConcepts,
		loadGenomicIndex, loadGenomicDir:
		return true
	}
	return false
}

func (s *loadScreen) update(msg tea.Msg) (*loadScreen, tea.Cmd) {
	// The async archive-csvs result is handled before any gate so it reaches the
	// inspecting file step regardless of which overlay (discard prompt) is up; its
	// own seq guard drops a result for a since-re-entered/closed step.
	if fill, ok := msg.(archiveCSVsFillMsg); ok {
		return s.applyArchiveCSVsFill(fill)
	}

	// A discard confirm owns the keyboard until answered. Swallow every
	// non-key message (huh/filepicker ticks) so the prompt stays put.
	if s.discarding {
		key, ok := msg.(tea.KeyMsg)
		if !ok {
			return s, nil
		}
		switch key.String() {
		case "y", "Y":
			return s, closeLoad(true)
		case "n", "N", "esc":
			s.discarding = false
		}
		return s, nil
	}

	// huh and the filepicker both ship esc disabled, but the footer advertises
	// "esc cancel" — intercept it here (as wizardScreen does). A screen with
	// collected input asks to confirm first; a pristine one closes immediately.
	if key, ok := msg.(tea.KeyMsg); ok && key.String() == "esc" {
		if s.dirty() {
			s.discarding = true
			return s, nil
		}
		return s, closeLoad(true)
	}

	// While the archive is being inspected the filebrowser is parked behind a
	// placeholder; only the fill (handled above) and esc/discard (above) act.
	// Swallow everything else so a stray filepicker tick can't re-select.
	if s.inspecting {
		return s, nil
	}

	switch s.step {
	case loadPhenoFile, loadPhenoDatasets, loadPhenoConcepts,
		loadPhenoFacetCategories, loadPhenoFacets, loadPhenoFacetConcepts,
		loadGenomicIndex, loadGenomicDir:
		var cmd tea.Cmd
		s.fb, cmd = s.fb.Update(msg)
		// Poll for a selection on this msg and consume it exactly once: the next
		// file step builds a fresh browser, so a fresh selection is never
		// confused with this step's.
		if path, ok := s.fb.Selected(); ok {
			return s.consumeFile(path)
		}
		return s, cmd

	default: // huh form steps: kind, heap, dict, facets-ask, confirm, archive entry
		return s.updateForm(msg)
	}
}

// updateForm pumps the active huh form and acts on its terminal state.
func (s *loadScreen) updateForm(msg tea.Msg) (*loadScreen, tea.Cmd) {
	form, cmd := s.form.Update(msg)
	if f, ok := form.(*huh.Form); ok {
		s.form = f
	}
	switch s.form.State {
	case huh.StateAborted:
		return s, closeLoad(true)
	case huh.StateCompleted:
		return s.formCompleted()
	}
	return s, cmd
}

// formCompleted routes a completed huh form to the next step.
func (s *loadScreen) formCompleted() (*loadScreen, tea.Cmd) {
	switch s.step {
	case loadKind:
		switch s.kind {
		case "phenotype":
			return s.enterStep(loadPhenoFile)
		case "genomic":
			// The genomic heap floor is higher than the phenotype default the
			// screen was constructed with; prefill the genomic default before the
			// heap input is reached (heap is not "collected"/dirty data).
			s.heap = defaultGenomicHeap
			return s.enterStep(loadGenomicIndex)
		default: // "" — Cancel
			return s, closeLoad(true)
		}
	case loadPhenoArchiveEntry:
		// archiveEntry is bound to the select and preselected to the first entry,
		// so it is always a real archive path here — store it and advance to heap.
		return s.enterStep(loadPhenoHeap)
	case loadPhenoHeap:
		return s.enterStep(loadPhenoDict)
	case loadPhenoDict:
		if s.dictMode == "custom" {
			return s.enterStep(loadPhenoDatasets)
		}
		return s.enterStep(loadConfirm)
	case loadPhenoFacetsAsk:
		if s.includeFacets {
			return s.enterStep(loadPhenoFacetCategories)
		}
		return s.enterStep(loadConfirm)
	case loadConfirm:
		if !s.confirmed {
			return s, closeLoad(true)
		}
		return s, s.dispatch()

	case loadGenomicDirAsk:
		if s.includeVCFDir {
			return s.enterStep(loadGenomicDir)
		}
		return s.enterStep(loadGenomicPartition)
	case loadGenomicPartition:
		return s.enterStep(loadGenomicHeap)
	case loadGenomicHeap:
		return s.enterStep(loadGenomicPromote)
	case loadGenomicPromote:
		return s.enterStep(loadGenomicProfile)
	case loadGenomicProfile:
		return s.enterStep(loadGenomicConfirm)
	case loadGenomicConfirm:
		if !s.confirmed {
			return s, closeLoad(true)
		}
		return s, s.dispatchGenomic()
	}
	return s, nil
}

// consumeFile stores a just-selected path into the field for the current file
// step and advances. Exported as the test seam the spec calls for: tests drive
// the state machine by calling this directly rather than the real filepicker.
func (s *loadScreen) consumeFile(path string) (*loadScreen, tea.Cmd) {
	switch s.step {
	case loadPhenoFile:
		s.file = path
		s.archiveErr = "" // a fresh pick retires any prior inspection error
		// A plain .csv loads verbatim — no archive to inspect, no entry to pick.
		// Anything else (.gz/.csv.gz/.tgz/.tar.gz) may be a tar holding multiple
		// CSVs, so inspect it asynchronously before choosing the next step.
		if isPlainCSV(path) {
			s.archiveEntry = "" // ensure a re-pick to plain CSV drops any stale entry
			return s.enterStep(loadPhenoHeap)
		}
		return s.startArchiveInspection(path)
	case loadPhenoDatasets:
		s.datasets = path
		return s.enterStep(loadPhenoConcepts)
	case loadPhenoConcepts:
		s.concepts = path
		return s.enterStep(loadPhenoFacetsAsk)
	case loadPhenoFacetCategories:
		s.facetCategories = path
		return s.enterStep(loadPhenoFacets)
	case loadPhenoFacets:
		s.facets = path
		return s.enterStep(loadPhenoFacetConcepts)
	case loadPhenoFacetConcepts:
		s.facetConcepts = path
		return s.enterStep(loadConfirm)
	case loadGenomicIndex:
		s.vcfIndex = path
		return s.enterStep(loadGenomicDirAsk)
	case loadGenomicDir:
		s.vcfDir = path
		return s.enterStep(loadGenomicPartition)
	}
	return s, nil
}

// isPlainCSV reports whether path is a raw, uncompressed CSV (the fast path that
// needs no archive inspection). A bare ".csv" suffix that is NOT also ".csv.gz"
// — the latter is a gzip the bash side decompresses — qualifies.
func isPlainCSV(path string) bool {
	return strings.HasSuffix(path, ".csv") && !strings.HasSuffix(path, ".csv.gz")
}

// startArchiveInspection parks the file step behind an "(inspecting archive…)"
// placeholder and schedules the read-only `etl.sh archive-csvs` lister in a
// tea.Cmd (it forks bash, so it must never run in Update). archiveSeq stamps the
// dispatch so a result for a since-re-entered/closed file step is dropped. The
// step stays loadPhenoFile while inspecting (the view keys off s.inspecting); the
// fill handler advances it. Mirrors landing.startDevPicker's async pattern.
func (s *loadScreen) startArchiveInspection(file string) (*loadScreen, tea.Cmd) {
	s.inspecting = true
	s.archiveErr = ""
	s.archiveEntries = nil
	s.archiveEntry = "" // a new inspection invalidates any prior entry choice
	s.archiveSeq++
	seq, root := s.archiveSeq, s.root
	return s, func() tea.Msg {
		entries, err := fetchArchiveCSVs(root, file)
		return archiveCSVsFillMsg{seq: seq, entries: entries, err: err}
	}
}

// applyArchiveCSVsFill lands the async archive-csvs result. Staleness is guarded
// by seq (a result for a since-re-entered/closed file step is dropped) and by
// requiring the inspection to still be in flight. Decision rule (LD-7a):
//   - error → surface it inline and let the user re-pick (stay on the file step).
//   - 0 or 1 entries → no picker; the bash side auto-picks a single-CSV tar and
//     handles a plain .gz, so advance to heap with ArchiveEntry empty.
//   - ≥2 entries → open the entry picker (loadPhenoArchiveEntry).
func (s *loadScreen) applyArchiveCSVsFill(msg archiveCSVsFillMsg) (*loadScreen, tea.Cmd) {
	if !s.inspecting || msg.seq != s.archiveSeq {
		return s, nil
	}
	s.inspecting = false
	if msg.err != nil {
		// Re-open the file browser so the user can pick a different file; the
		// inline error tells them why the chosen one was rejected.
		s.archiveErr = "could not inspect archive: " + msg.err.Error()
		return s.enterStep(loadPhenoFile)
	}
	if len(msg.entries) >= 2 {
		s.archiveEntries = msg.entries
		// Preselect the first entry so the select cursor starts on a real option
		// (never on an empty/zero value — the afa885b cursor-on-Cancel lesson).
		s.archiveEntry = msg.entries[0]
		return s.enterStep(loadPhenoArchiveEntry)
	}
	// 0 or 1 CSV: nothing to choose — leave ArchiveEntry empty and let bash
	// auto-pick (single-CSV tar) or decompress (plain gzip / empty .gz output).
	s.archiveEntries = nil
	return s.enterStep(loadPhenoHeap)
}

// enterStep sets the step and constructs (and sizes) its form or filebrowser,
// returning the model's Init command.
func (s *loadScreen) enterStep(step loadStep) (*loadScreen, tea.Cmd) {
	s.step = step
	switch step {
	case loadPhenoFile:
		// Accept raw CSVs and the compressed/archived forms LD-7a handles. The
		// filebrowser does suffix matching, so ".gz" also admits ".csv.gz" and
		// ".tar.gz", and ".tgz" admits ".tgz".
		return s.openBrowser([]string{".csv", ".gz", ".tgz"}, "Select the phenotype CSV (.csv/.gz/.tgz)")
	case loadPhenoArchiveEntry:
		s.form = s.sizeForm(s.buildArchiveEntryForm())
		return s, s.form.Init()
	case loadPhenoHeap:
		s.form = s.sizeForm(s.buildHeapForm())
		return s, s.form.Init()
	case loadPhenoDict:
		s.form = s.sizeForm(s.buildDictForm())
		return s, s.form.Init()
	case loadPhenoDatasets:
		return s.openBrowser([]string{".csv"}, "Select datasets.csv")
	case loadPhenoConcepts:
		return s.openBrowser([]string{".zip"}, "Select concepts.zip")
	case loadPhenoFacetsAsk:
		s.form = s.sizeForm(s.buildFacetsForm())
		return s, s.form.Init()
	case loadPhenoFacetCategories:
		return s.openBrowser([]string{".csv"}, "Select facet_categories.csv")
	case loadPhenoFacets:
		return s.openBrowser([]string{".csv"}, "Select facets.csv")
	case loadPhenoFacetConcepts:
		return s.openBrowser([]string{".csv"}, "Select facet_concepts.csv")
	case loadConfirm:
		s.form = s.sizeForm(s.buildConfirmForm())
		return s, s.form.Init()

	case loadGenomicIndex:
		return s.openBrowser([]string{".tsv"}, "Select the VCF index TSV")
	case loadGenomicDirAsk:
		s.form = s.sizeForm(s.buildGenomicDirAskForm())
		return s, s.form.Init()
	case loadGenomicDir:
		return s.openDirBrowser("Select the directory of VCF files")
	case loadGenomicPartition:
		s.form = s.sizeForm(s.buildPartitionForm())
		return s, s.form.Init()
	case loadGenomicHeap:
		s.form = s.sizeForm(s.buildGenomicHeapForm())
		return s, s.form.Init()
	case loadGenomicPromote:
		s.form = s.sizeForm(s.buildPromoteForm())
		return s, s.form.Init()
	case loadGenomicProfile:
		s.form = s.sizeForm(s.buildProfileForm())
		return s, s.form.Init()
	case loadGenomicConfirm:
		s.form = s.sizeForm(s.buildGenomicConfirmForm())
		return s, s.form.Init()
	}
	return s, nil
}

func (s *loadScreen) openBrowser(exts []string, title string) (*loadScreen, tea.Cmd) {
	s.fb = filebrowser.New(filebrowser.Options{AllowedExts: exts, Title: title})
	s.fb.SetSize(s.fbWidth(), s.fbHeight())
	return s, s.fb.Init()
}

// openDirBrowser opens a DirMode filebrowser for selecting a directory (the
// optional --vcf-dir override).
func (s *loadScreen) openDirBrowser(title string) (*loadScreen, tea.Cmd) {
	s.fb = filebrowser.New(filebrowser.Options{DirMode: true, Title: title})
	s.fb.SetSize(s.fbWidth(), s.fbHeight())
	return s, s.fb.Init()
}

// dirty reports whether any data has been collected (any file path set). The
// dictionary mode, kind selection, and heap default are not "collected input" —
// only a chosen file path is — so the kind-select closes pristinely. On the
// genomic branch the screen turns dirty once the VCF index is selected.
func (s *loadScreen) dirty() bool {
	return s.file != "" || s.datasets != "" || s.concepts != "" ||
		s.facetCategories != "" || s.facets != "" || s.facetConcepts != "" ||
		s.vcfIndex != "" || s.vcfDir != ""
}

// opts assembles the PhenotypeOpts from the collected values; facet fields are
// forwarded only in custom mode with facets included.
func (s *loadScreen) opts() actions.PhenotypeOpts {
	o := actions.PhenotypeOpts{
		File:             s.file,
		ArchiveEntry:     s.archiveEntry,
		Heap:             s.heap,
		CustomDictionary: s.dictMode == "custom",
	}
	if o.CustomDictionary {
		o.Datasets = s.datasets
		o.Concepts = s.concepts
		if s.includeFacets {
			o.FacetCategories = s.facetCategories
			o.Facets = s.facets
			o.FacetConcepts = s.facetConcepts
		}
	}
	return o
}

func (s *loadScreen) dispatch() tea.Cmd {
	act := actions.LoadPhenotype(s.opts())
	return func() tea.Msg { return runActionMsg{act: act} }
}

// genomicOpts assembles the GenomicOpts from the collected genomic values.
// VCFDir is forwarded only when the user opted to point at a directory.
func (s *loadScreen) genomicOpts() actions.GenomicOpts {
	o := actions.GenomicOpts{
		Partition:     s.partition,
		VCFIndex:      s.vcfIndex,
		Heap:          s.heap,
		Promote:       s.promote,
		EnableProfile: s.enableProfile,
	}
	if s.includeVCFDir {
		o.VCFDir = s.vcfDir
	}
	return o
}

func (s *loadScreen) dispatchGenomic() tea.Cmd {
	act := actions.LoadGenomic(s.genomicOpts())
	return func() tea.Msg { return runActionMsg{act: act} }
}

func closeLoad(aborted bool) tea.Cmd {
	return func() tea.Msg { return loadDataClosedMsg{aborted: aborted} }
}

// --- form builders (Value bound before Options, per the huh gotcha) ---------

func (s *loadScreen) buildKindForm() *huh.Form {
	// No .Title here: the screen already renders the "Load your data" header via
	// loadTitleStyle, so a form title would double-render it on the kind step.
	return huh.NewForm(huh.NewGroup(
		huh.NewSelect[string]().
			Description("Choose the kind of data to load into PIC-SURE.").
			Value(&s.kind).
			Options(
				huh.NewOption("Phenotype data (CSV)", "phenotype"),
				huh.NewOption("Genomic data (VCF)", "genomic"),
				huh.NewOption("Cancel", ""),
			),
	))
}

// buildArchiveEntryForm lists the CSV entries found inside a multi-CSV archive
// so the user picks which one to load (forwarded as --entry). No Cancel option:
// esc backs out of the whole step (the screen's esc handler owns cancel), so the
// select carries only real entries and the cursor preselects archiveEntry (set
// to the first entry by applyArchiveCSVsFill) — never an empty value that would
// reintroduce the cursor-on-Cancel collision. Value is bound BEFORE Options, per
// the huh gotcha.
func (s *loadScreen) buildArchiveEntryForm() *huh.Form {
	opts := make([]huh.Option[string], 0, len(s.archiveEntries))
	for _, e := range s.archiveEntries {
		opts = append(opts, huh.NewOption(e, e))
	}
	return huh.NewForm(huh.NewGroup(
		huh.NewSelect[string]().
			Title("Choose the CSV to load").
			Description("This archive holds multiple CSVs — pick the phenotype CSV to load.").
			Value(&s.archiveEntry).
			Options(opts...),
	))
}

func (s *loadScreen) buildHeapForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewInput().
			Title("JVM heap size").
			Description("MB; 4096 for <1M rows, 8000+ for larger.").
			Value(&s.heap).
			Validate(validateHeap),
	))
}

func (s *loadScreen) buildDictForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewSelect[string]().
			Title("Dictionary").
			Description("How to build the data dictionary for the loaded phenotype data.").
			Value(&s.dictMode).
			Options(
				huh.NewOption("Auto — rebuild dictionary from the loaded data (recommended)", "auto"),
				huh.NewOption("Custom — supply dictionary CSVs", "custom"),
			),
	))
}

func (s *loadScreen) buildFacetsForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewConfirm().
			Title("Include facet metadata?").
			Description("Optionally supply facet_categories.csv, facets.csv, and facet_concepts.csv\n(all three together, or none).").
			Affirmative("Yes").
			Negative("No").
			Value(&s.includeFacets),
	))
}

func (s *loadScreen) buildConfirmForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewConfirm().
			Title("⚠ Load phenotype data — this REPLACES existing HPDS phenotype data").
			Description(s.confirmSummary()).
			Affirmative("Load").
			Negative("Cancel").
			Value(&s.confirmed),
	))
}

// --- genomic-branch form builders -------------------------------------------

func (s *loadScreen) buildGenomicDirAskForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewConfirm().
			Title("VCF directory").
			Description("Point at a directory of VCF files?\n(the index may already use absolute paths)").
			Affirmative("Yes").
			Negative("No").
			Value(&s.includeVCFDir),
	))
}

func (s *loadScreen) buildPartitionForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewInput().
			Title("Genomic partition").
			Description("letters/digits/_/- ; names the genomic dataset.").
			Value(&s.partition).
			Validate(validatePartition),
	))
}

func (s *loadScreen) buildGenomicHeapForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewInput().
			Title("JVM heap size").
			Description("MB; 16000 for typical loads, raise for large partitions.").
			Value(&s.heap).
			Validate(validateHeap),
	))
}

func (s *loadScreen) buildPromoteForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewConfirm().
			Title("Promote this load to live genomic data now?").
			Description("A backup of the current genomic data is kept (promote is backup-safe).").
			Affirmative("Yes").
			Negative("No").
			Value(&s.promote),
	))
}

func (s *loadScreen) buildProfileForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewConfirm().
			Title("Enable the genomic HPDS profile now?").
			Description("Only if data will be present — otherwise HPDS can crash-loop.").
			Affirmative("Yes").
			Negative("No").
			Value(&s.enableProfile),
	))
}

func (s *loadScreen) buildGenomicConfirmForm() *huh.Form {
	return huh.NewForm(huh.NewGroup(
		huh.NewConfirm().
			Title("⚠ Load genomic data").
			Description(s.genomicConfirmSummary()).
			Affirmative("Load").
			Negative("Cancel").
			Value(&s.confirmed),
	))
}

// validateHeap accepts a non-empty numeric (MB) heap value.
func validateHeap(v string) error {
	v = strings.TrimSpace(v)
	if v == "" {
		return errors.New("heap is required (e.g. 4096)")
	}
	for _, r := range v {
		if r < '0' || r > '9' {
			return errors.New("heap must be numeric (MB), e.g. 4096")
		}
	}
	return nil
}

// partitionPattern mirrors etl.sh load-genomic's own partition guard
// (^[A-Za-z0-9_-]+$): a non-empty run of letters, digits, underscores, hyphens.
var partitionPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// validatePartition accepts a non-empty partition name of letters/digits/_/-.
func validatePartition(v string) error {
	v = strings.TrimSpace(v)
	if v == "" {
		return errors.New("partition is required")
	}
	if !partitionPattern.MatchString(v) {
		return errors.New("partition must match ^[A-Za-z0-9_-]+$ (letters/digits/_/-)")
	}
	return nil
}

// confirmSummary leads with the action's honest Describe warning (phenotype
// REPLACES existing HPDS data) and follows with an aligned title/value digest
// of everything collected — the U8 confirm-summary idiom: titles padded with
// spaces to the widest visible title, a two-space gap, then the value.
func (s *loadScreen) confirmSummary() string {
	rows := [][2]string{
		{"File", s.file},
	}
	// For a multi-CSV archive the file line is the archive path; name the chosen
	// entry on its own line so the user sees exactly which CSV will load.
	if s.archiveEntry != "" {
		rows = append(rows, [2]string{"Archive entry", s.archiveEntry})
	}
	rows = append(rows, [2]string{"Heap", s.heap + " MB"})
	if s.dictMode == "custom" {
		rows = append(rows,
			[2]string{"Dictionary", "custom"},
			[2]string{"Datasets", s.datasets},
			[2]string{"Concepts", s.concepts},
		)
		if s.includeFacets {
			rows = append(rows,
				[2]string{"Facet categories", s.facetCategories},
				[2]string{"Facets", s.facets},
				[2]string{"Facet concepts", s.facetConcepts},
			)
		}
	} else {
		rows = append(rows, [2]string{"Dictionary", "auto (rebuild from loaded data)"})
	}

	titleWidth := 0
	for _, r := range rows {
		if w := lipgloss.Width(r[0]); w > titleWidth {
			titleWidth = w
		}
	}

	var b strings.Builder
	b.WriteString(actions.LoadPhenotype(s.opts()).Describe)
	b.WriteString("\n\n")
	for _, r := range rows {
		pad := strings.Repeat(" ", titleWidth-lipgloss.Width(r[0]))
		fmt.Fprintf(&b, "%s%s  %s\n", r[0], pad, r[1])
	}
	return strings.TrimRight(b.String(), "\n")
}

// genomicConfirmSummary leads with the action's Describe, follows with the two
// genomic caveats — promote is backup-safe, and enabling the profile before
// genomic data is present crash-loops HPDS — and closes with an aligned digest
// of the collected values (the same U8 confirm-summary idiom as confirmSummary).
//
// The screen cannot know whether prior genomic data is already live, so the
// risky combination (enable-profile=true with promote=false) is surfaced as a
// prominent CONDITIONAL warning rather than a flat assertion.
func (s *loadScreen) genomicConfirmSummary() string {
	vcfDir := s.vcfDir
	if !s.includeVCFDir || vcfDir == "" {
		vcfDir = "(index paths)"
	}
	rows := [][2]string{
		{"Partition", s.partition},
		{"VCF index", s.vcfIndex},
		{"VCF dir", vcfDir},
		{"Heap", s.heap + " MB"},
		{"Promote", yesNo(s.promote)},
		{"Enable profile", yesNo(s.enableProfile)},
	}

	titleWidth := 0
	for _, r := range rows {
		if w := lipgloss.Width(r[0]); w > titleWidth {
			titleWidth = w
		}
	}

	var b strings.Builder
	b.WriteString(actions.LoadGenomic(s.genomicOpts()).Describe)
	b.WriteString("\n\n")
	b.WriteString("Caveats:\n")
	b.WriteString("• Promote is backup-safe: the previous genomic data volume is kept until\n" +
		"  explicitly removed.\n")
	if s.enableProfile && !s.promote {
		// Risky combo: enabling the profile without promoting this load. We can't
		// know whether prior genomic data is already live, so warn conditionally.
		b.WriteString("⚠ You enabled the profile WITHOUT promoting this load. If no prior\n" +
			"  genomic data is already live, enabling the HPDS genomic profile will\n" +
			"  crash-loop HPDS. Only proceed if promoted genomic data is already present\n" +
			"  (or also promote this load).\n")
	} else {
		b.WriteString("• Enabling the genomic profile before genomic data is present crash-loops\n" +
			"  HPDS — only enable it once promoted data exists.\n")
	}
	b.WriteString("\n")
	for _, r := range rows {
		pad := strings.Repeat(" ", titleWidth-lipgloss.Width(r[0]))
		fmt.Fprintf(&b, "%s%s  %s\n", r[0], pad, r[1])
	}
	return strings.TrimRight(b.String(), "\n")
}

// yesNo renders a bool as a confirm-summary "yes"/"no" cell.
func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func (s *loadScreen) view() string {
	var body, footer string
	switch {
	case s.inspecting:
		// The archive-csvs lister is running; park the file browser behind a brief
		// placeholder so the screen doesn't look frozen during the bash fork.
		body = loadTitleStyle.Render("(inspecting archive…)")
		footer = loadFooterStyle.Render("esc cancel")
	case isFileStep(s.step):
		fbView := s.fb.View()
		// Surface a failed archive inspection inline above the re-opened browser so
		// the user knows why their previous pick was rejected and can re-pick.
		if s.archiveErr != "" {
			fbView = lipgloss.JoinVertical(lipgloss.Left, styles.Bad.Render(s.archiveErr), fbView)
		}
		body = fbView
		footer = loadFooterStyle.Render("enter select · esc cancel")
	default:
		body = s.form.View()
		footer = loadFooterStyle.Render("esc cancel")
	}
	if s.discarding {
		footer = loadFooterStyle.Render("Discard data load? (y/n)")
	}

	content := lipgloss.JoinVertical(lipgloss.Left,
		loadTitleStyle.Render("Load your data"), body, footer)
	if s.width == 0 || s.height == 0 {
		return content
	}
	return lipgloss.Place(s.width, s.height, lipgloss.Center, lipgloss.Center, content)
}
