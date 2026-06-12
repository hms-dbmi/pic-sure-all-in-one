package tui

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// completeForm forces the active huh form to its completed state and pumps a
// neutral message so the screen acts on it — the same bypass the landing and
// wizard tests use, since huh's interactive completion is not unit-testable.
func completeForm(s *loadScreen) (*loadScreen, tea.Cmd) {
	s.form.State = huh.StateCompleted
	return s.update(struct{}{})
}

// TestLoadWizardPhenotypeAutoFlow drives the whole auto-dictionary happy path:
// kind → file → heap → dictionary(auto) → confirm → dispatch, and asserts the
// dispatched runActionMsg carries LoadPhenotype with the collected File/Heap
// and CustomDictionary=false.
func TestLoadWizardPhenotypeAutoFlow(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)

	// kind: phenotype.
	s.kind = "phenotype"
	s, _ = completeForm(s)
	if s.step != loadPhenoFile {
		t.Fatalf("after kind=phenotype, step = %v, want loadPhenoFile", s.step)
	}

	// file: consume a selection (the test seam — we don't drive the filepicker).
	s, _ = s.consumeFile("/data/pheno.csv")
	if s.step != loadPhenoHeap || s.file != "/data/pheno.csv" {
		t.Fatalf("after file select, step=%v file=%q", s.step, s.file)
	}

	// heap: keep the prefilled default.
	if s.heap != defaultHeap {
		t.Fatalf("heap default = %q, want %q", s.heap, defaultHeap)
	}
	s, _ = completeForm(s)
	if s.step != loadPhenoDict {
		t.Fatalf("after heap, step = %v, want loadPhenoDict", s.step)
	}

	// dictionary: auto → straight to confirm.
	s.dictMode = "auto"
	s, _ = completeForm(s)
	if s.step != loadConfirm {
		t.Fatalf("after dict=auto, step = %v, want loadConfirm", s.step)
	}

	// confirm: Load.
	s.confirmed = true
	_, cmd := completeForm(s)
	if cmd == nil {
		t.Fatal("confirm produced no command")
	}
	run, ok := cmd().(runActionMsg)
	if !ok {
		t.Fatalf("dispatch = %#v, want runActionMsg", cmd())
	}
	if run.act.Script != "etl.sh" {
		t.Errorf("script = %q, want etl.sh", run.act.Script)
	}
	want := []string{"load-phenotype", "--file", "/data/pheno.csv", "--heap", defaultHeap}
	if !eq(run.act.Args, want) {
		t.Errorf("args = %v, want %v (auto dictionary, no --dictionary custom)", run.act.Args, want)
	}
}

// TestLoadWizardCustomNoFacets: dictionary(custom) → datasets → concepts →
// facets(no) → confirm → dispatch with CustomDictionary=true, Datasets/Concepts
// set and the facet fields empty.
func TestLoadWizardCustomNoFacets(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)

	s.kind = "phenotype"
	s, _ = completeForm(s)
	s, _ = s.consumeFile("/data/pheno.csv")
	s, _ = completeForm(s) // heap default → dict

	// dictionary: custom → datasets file step.
	s.dictMode = "custom"
	s, _ = completeForm(s)
	if s.step != loadPhenoDatasets {
		t.Fatalf("after dict=custom, step = %v, want loadPhenoDatasets", s.step)
	}
	s, _ = s.consumeFile("/data/datasets.csv")
	if s.step != loadPhenoConcepts {
		t.Fatalf("after datasets, step = %v, want loadPhenoConcepts", s.step)
	}
	s, _ = s.consumeFile("/data/concepts.zip")
	if s.step != loadPhenoFacetsAsk {
		t.Fatalf("after concepts, step = %v, want loadPhenoFacetsAsk", s.step)
	}

	// facets: no → straight to confirm.
	s.includeFacets = false
	s, _ = completeForm(s)
	if s.step != loadConfirm {
		t.Fatalf("after facets=no, step = %v, want loadConfirm", s.step)
	}

	s.confirmed = true
	_, cmd := completeForm(s)
	run, ok := cmd().(runActionMsg)
	if !ok {
		t.Fatalf("dispatch = %#v, want runActionMsg", cmd())
	}
	want := []string{
		"load-phenotype", "--file", "/data/pheno.csv", "--heap", defaultHeap,
		"--dictionary", "custom",
		"--datasets", "/data/datasets.csv",
		"--concepts", "/data/concepts.zip",
	}
	if !eq(run.act.Args, want) {
		t.Errorf("args = %v, want %v (custom, no facets)", run.act.Args, want)
	}
}

// TestLoadWizardCustomWithFacets: facets(yes) collects the three facet files
// and forwards them.
func TestLoadWizardCustomWithFacets(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)

	s.kind = "phenotype"
	s, _ = completeForm(s)
	s, _ = s.consumeFile("/data/pheno.csv")
	s, _ = completeForm(s) // heap → dict
	s.dictMode = "custom"
	s, _ = completeForm(s)
	s, _ = s.consumeFile("/data/datasets.csv")
	s, _ = s.consumeFile("/data/concepts.zip")

	// facets: yes → three file steps.
	s.includeFacets = true
	s, _ = completeForm(s)
	if s.step != loadPhenoFacetCategories {
		t.Fatalf("after facets=yes, step = %v, want loadPhenoFacetCategories", s.step)
	}
	s, _ = s.consumeFile("/data/facet_categories.csv")
	if s.step != loadPhenoFacets {
		t.Fatalf("after facet categories, step = %v, want loadPhenoFacets", s.step)
	}
	s, _ = s.consumeFile("/data/facets.csv")
	if s.step != loadPhenoFacetConcepts {
		t.Fatalf("after facets, step = %v, want loadPhenoFacetConcepts", s.step)
	}
	s, _ = s.consumeFile("/data/facet_concepts.csv")
	if s.step != loadConfirm {
		t.Fatalf("after facet concepts, step = %v, want loadConfirm", s.step)
	}

	s.confirmed = true
	_, cmd := completeForm(s)
	run, ok := cmd().(runActionMsg)
	if !ok {
		t.Fatalf("dispatch = %#v, want runActionMsg", cmd())
	}
	want := []string{
		"load-phenotype", "--file", "/data/pheno.csv", "--heap", defaultHeap,
		"--dictionary", "custom",
		"--datasets", "/data/datasets.csv",
		"--concepts", "/data/concepts.zip",
		"--facets-categories", "/data/facet_categories.csv",
		"--facets", "/data/facets.csv",
		"--facet-concepts", "/data/facet_concepts.csv",
	}
	if !eq(run.act.Args, want) {
		t.Errorf("args = %v, want %v (custom with facets)", run.act.Args, want)
	}
}

// TestLoadWizardConfirmCancelCloses: declining at the confirm summary closes
// the screen without dispatching a load.
func TestLoadWizardConfirmCancelCloses(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s.kind = "phenotype"
	s, _ = completeForm(s)
	s, _ = s.consumeFile("/data/pheno.csv")
	s, _ = completeForm(s) // heap
	s.dictMode = "auto"
	s, _ = completeForm(s) // → confirm

	s.confirmed = false
	_, cmd := completeForm(s)
	if cmd == nil {
		t.Fatal("declined confirm produced no command")
	}
	msg, ok := cmd().(loadDataClosedMsg)
	if !ok || !msg.aborted {
		t.Fatalf("declined confirm = %#v, want loadDataClosedMsg{aborted:true}", cmd())
	}
}

// TestLoadWizardKindCancelCloses: the Cancel option on the kind select closes.
func TestLoadWizardKindCancelCloses(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.kind = "" // Cancel
	_, cmd := completeForm(s)
	if cmd == nil {
		t.Fatal("kind cancel produced no command")
	}
	if msg, ok := cmd().(loadDataClosedMsg); !ok || !msg.aborted {
		t.Fatalf("kind cancel = %#v, want loadDataClosedMsg{aborted:true}", cmd())
	}
}

// TestLoadWizardGenomicRoutesToStub: picking genomic routes to the coming-soon
// stub — it must NOT dispatch a phenotype load, and the view shows the
// placeholder. LD-5 replaces the stub.
func TestLoadWizardGenomicRoutesToStub(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s.kind = "genomic"
	s, cmd := completeForm(s)
	if s.step != loadGenomicStub {
		t.Fatalf("genomic kind step = %v, want loadGenomicStub", s.step)
	}
	if cmd != nil {
		if _, ok := cmd().(runActionMsg); ok {
			t.Fatal("genomic stub dispatched a run action; LD-5 has not built it yet")
		}
	}
	if !strings.Contains(wizardANSI.ReplaceAllString(s.view(), ""), "coming soon") {
		t.Errorf("genomic stub view missing the coming-soon notice:\n%s", wizardANSI.ReplaceAllString(s.view(), ""))
	}
	// Any key on the stub returns to the menu (no dispatch).
	_, cmd = s.update(tea.KeyMsg{Type: tea.KeyEnter})
	if msg, ok := cmd().(loadDataClosedMsg); !ok || !msg.aborted {
		t.Fatalf("stub enter = %#v, want loadDataClosedMsg{aborted:true}", cmd())
	}
}

// TestLoadWizardEscPristineCloses: esc at the kind-select (no input collected)
// closes immediately with no discard prompt.
func TestLoadWizardEscPristineCloses(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s2, cmd := s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if s2.discarding {
		t.Fatal("pristine esc raised the discard prompt")
	}
	if cmd == nil {
		t.Fatal("pristine esc produced no command")
	}
	if msg, ok := cmd().(loadDataClosedMsg); !ok || !msg.aborted {
		t.Fatalf("pristine esc = %#v, want loadDataClosedMsg{aborted:true}", cmd())
	}
}

// TestLoadWizardEscDirtyGuard: once a file is collected, esc raises the
// "Discard data load?" prompt; y discards (closes), n keeps the screen.
func TestLoadWizardEscDirtyGuard(t *testing.T) {
	dirty := func(t *testing.T) *loadScreen {
		t.Helper()
		s := newLoadScreen("/tmp/x")
		s.setSize(100, 35)
		s.kind = "phenotype"
		s, _ = completeForm(s)
		s, _ = s.consumeFile("/data/pheno.csv") // now dirty
		if !s.dirty() {
			t.Fatal("setup: screen should be dirty after a file selection")
		}
		return s
	}

	// esc on a dirty screen raises the prompt (no close yet).
	s := dirty(t)
	s, cmd := s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if !s.discarding {
		t.Fatal("esc on a dirty screen did not raise the discard prompt")
	}
	if cmd != nil {
		t.Fatal("esc on a dirty screen must not close yet")
	}
	if !strings.Contains(wizardANSI.ReplaceAllString(s.view(), ""), "Discard data load?") {
		t.Errorf("footer missing the discard prompt:\n%s", wizardANSI.ReplaceAllString(s.view(), ""))
	}

	// y discards (closes aborted).
	s = dirty(t)
	s, _ = s.update(tea.KeyMsg{Type: tea.KeyEsc})
	_, cmd = s.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	if msg, ok := cmd().(loadDataClosedMsg); !ok || !msg.aborted {
		t.Fatalf("y at discard prompt = %#v, want loadDataClosedMsg{aborted:true}", cmd())
	}

	// n keeps the screen (prompt dismissed, collected file intact).
	s = dirty(t)
	s, _ = s.update(tea.KeyMsg{Type: tea.KeyEsc})
	s, cmd = s.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}})
	if cmd != nil {
		t.Fatal("n at discard prompt should not close the screen")
	}
	if s.discarding {
		t.Fatal("n did not dismiss the discard prompt")
	}
	if s.file != "/data/pheno.csv" {
		t.Errorf("collected file lost after declining discard: %q", s.file)
	}
}

// TestLoadWizardConfirmSummaryLeadsWithWarning: the confirm summary leads with
// the action's honest "REPLACES existing HPDS phenotype data" warning and lists
// the collected values.
func TestLoadWizardConfirmSummaryLeadsWithWarning(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s.kind = "phenotype"
	s, _ = completeForm(s)
	s, _ = s.consumeFile("/data/pheno.csv")
	s, _ = completeForm(s) // heap
	s.dictMode = "auto"
	s, _ = completeForm(s) // → confirm

	view := wizardANSI.ReplaceAllString(s.view(), "")
	for _, want := range []string{"REPLACES existing HPDS phenotype data", "/data/pheno.csv", defaultHeap} {
		if !strings.Contains(view, want) {
			t.Errorf("confirm summary missing %q:\n%s", want, view)
		}
	}
}

// TestLoadWizardFrameStaysInBox: across the size matrix and both color profiles
// (TrueColor and the Ascii profile lipgloss resolves NO_COLOR to — the
// package's idiom; see TestLandingColorProfileSGR) the screen renders without
// panicking and never overflows the terminal box.
func TestLoadWizardFrameStaysInBox(t *testing.T) {
	restore := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(restore) })

	for _, profile := range []termenv.Profile{termenv.TrueColor, termenv.Ascii} {
		lipgloss.SetColorProfile(profile)
		for _, w := range []int{80, 120, 200} {
			h := 30
			// Exercise a representative step from each kind: the kind select
			// (form), a file step (filebrowser), the genomic stub, and the
			// confirm summary.
			for _, step := range []loadStep{loadKind, loadPhenoFile, loadGenomicStub, loadConfirm} {
				s := newLoadScreen("/tmp/x")
				s.setSize(w, h)
				switch step {
				case loadPhenoFile:
					s.kind = "phenotype"
					s, _ = completeForm(s)
				case loadGenomicStub:
					s.kind = "genomic"
					s, _ = completeForm(s)
				case loadConfirm:
					s.kind = "phenotype"
					s, _ = completeForm(s)
					s, _ = s.consumeFile("/data/pheno.csv")
					s, _ = completeForm(s)
					s.dictMode = "auto"
					s, _ = completeForm(s)
				}
				s.setSize(w, h) // re-size after entering the step
				view := s.view()
				if lipgloss.Height(view) > h {
					t.Errorf("profile=%v %dx%d step=%v frame height %d exceeds %d", profile, w, h, step, lipgloss.Height(view), h)
				}
				for n, line := range strings.Split(view, "\n") {
					if lw := lipgloss.Width(line); lw > w {
						t.Errorf("profile=%v %dx%d step=%v line %d width %d exceeds %d", profile, w, h, step, n, lw, w)
					}
				}
			}
		}
	}
}
