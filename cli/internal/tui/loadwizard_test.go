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

// genomicInputs is the set of values driveGenomicToConfirm walks through the
// genomic step chain. An empty heap keeps the prefilled genomic default.
type genomicInputs struct {
	vcfIndex      string
	includeVCFDir bool
	vcfDir        string
	partition     string
	heap          string
	promote       bool
	enableProfile bool
}

// driveGenomicToConfirm walks the genomic branch from the kind select to the
// confirm summary (form built, not yet confirmed), asserting each transition,
// and returns the screen parked at loadGenomicConfirm.
func driveGenomicToConfirm(t *testing.T, s *loadScreen, in genomicInputs) *loadScreen {
	t.Helper()

	s.kind = "genomic"
	s, _ = completeForm(s)
	if s.step != loadGenomicIndex {
		t.Fatalf("kind=genomic step = %v, want loadGenomicIndex", s.step)
	}

	s, _ = s.consumeFile(in.vcfIndex)
	if s.step != loadGenomicDirAsk || s.vcfIndex != in.vcfIndex {
		t.Fatalf("after vcf-index step=%v vcfIndex=%q", s.step, s.vcfIndex)
	}

	s.includeVCFDir = in.includeVCFDir
	s, _ = completeForm(s)
	if in.includeVCFDir {
		if s.step != loadGenomicDir {
			t.Fatalf("dir-ask=yes step = %v, want loadGenomicDir", s.step)
		}
		s, _ = s.consumeFile(in.vcfDir)
	}
	if s.step != loadGenomicPartition {
		t.Fatalf("before partition step = %v, want loadGenomicPartition", s.step)
	}

	s.partition = in.partition
	s, _ = completeForm(s)
	if s.step != loadGenomicHeap {
		t.Fatalf("after partition step = %v, want loadGenomicHeap", s.step)
	}

	if in.heap != "" {
		s.heap = in.heap
	}
	s, _ = completeForm(s)
	if s.step != loadGenomicPromote {
		t.Fatalf("after heap step = %v, want loadGenomicPromote", s.step)
	}

	s.promote = in.promote
	s, _ = completeForm(s)
	if s.step != loadGenomicProfile {
		t.Fatalf("after promote step = %v, want loadGenomicProfile", s.step)
	}

	s.enableProfile = in.enableProfile
	s, _ = completeForm(s)
	if s.step != loadGenomicConfirm {
		t.Fatalf("after profile step = %v, want loadGenomicConfirm", s.step)
	}
	return s
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

// TestLoadWizardGenomicRoutesToFile: picking genomic routes into the genomic
// branch's first (VCF index) file step — not a phenotype load, not the old
// coming-soon stub — and prefills the higher genomic heap default.
func TestLoadWizardGenomicRoutesToFile(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s.kind = "genomic"
	s, cmd := completeForm(s)
	if s.step != loadGenomicIndex {
		t.Fatalf("genomic kind step = %v, want loadGenomicIndex", s.step)
	}
	if !isFileStep(s.step) {
		t.Fatalf("loadGenomicIndex should be a file step")
	}
	if s.heap != defaultGenomicHeap {
		t.Errorf("genomic heap default = %q, want %q", s.heap, defaultGenomicHeap)
	}
	// Routing to a file step must not dispatch anything yet.
	if cmd != nil {
		if _, ok := cmd().(runActionMsg); ok {
			t.Fatal("entering the genomic file step dispatched a run action")
		}
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
			// (form), a phenotype file step (filebrowser), the phenotype confirm
			// summary, and the genomic confirm summary (the longest/wrappiest one).
			for _, step := range []loadStep{loadKind, loadPhenoFile, loadConfirm, loadGenomicConfirm} {
				s := newLoadScreen("/tmp/x")
				s.setSize(w, h)
				switch step {
				case loadPhenoFile:
					s.kind = "phenotype"
					s, _ = completeForm(s)
				case loadConfirm:
					s.kind = "phenotype"
					s, _ = completeForm(s)
					s, _ = s.consumeFile("/data/pheno.csv")
					s, _ = completeForm(s)
					s.dictMode = "auto"
					s, _ = completeForm(s)
				case loadGenomicConfirm:
					s = driveGenomicToConfirm(t, s, genomicInputs{
						vcfIndex:      "/data/idx.tsv",
						partition:     "chr22",
						promote:       false,
						enableProfile: true, // exercise the long conditional warning
					})
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

// TestLoadWizardGenomicFullFlow drives the whole genomic happy path including a
// VCF dir override and both toggles on, and asserts the dispatched runActionMsg
// carries LoadGenomic with the collected values and the exact argv.
func TestLoadWizardGenomicFullFlow(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)

	s = driveGenomicToConfirm(t, s, genomicInputs{
		vcfIndex:      "/data/idx.tsv",
		includeVCFDir: true,
		vcfDir:        "/data/vcf",
		partition:     "chr22",
		promote:       true,
		enableProfile: true,
	})
	if s.vcfDir != "/data/vcf" || s.heap != defaultGenomicHeap {
		t.Fatalf("collected vcfDir=%q heap=%q", s.vcfDir, s.heap)
	}

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
	if run.act.Name != "load genomic data" {
		t.Errorf("action name = %q, want %q", run.act.Name, "load genomic data")
	}
	want := []string{
		"load-genomic", "--partition", "chr22", "--vcf-index", "/data/idx.tsv",
		"--vcf-dir", "/data/vcf", "--heap", defaultGenomicHeap,
		"--promote", "--enable-profile",
	}
	if !eq(run.act.Args, want) {
		t.Errorf("args = %v, want %v", run.act.Args, want)
	}
}

// TestLoadWizardGenomicVCFDirBranch: declining the dir prompt leaves VCFDir
// empty (no --vcf-dir in argv); accepting it collects the directory and emits
// --vcf-dir.
func TestLoadWizardGenomicVCFDirBranch(t *testing.T) {
	// no → skip straight to partition, no --vcf-dir.
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s = driveGenomicToConfirm(t, s, genomicInputs{
		vcfIndex: "/data/idx.tsv", partition: "chr22",
	})
	if s.vcfDir != "" {
		t.Errorf("dir-ask=no left vcfDir=%q, want empty", s.vcfDir)
	}
	s.confirmed = true
	_, cmd := completeForm(s)
	run := cmd().(runActionMsg)
	for _, a := range run.act.Args {
		if a == "--vcf-dir" {
			t.Errorf("dir-ask=no but argv has --vcf-dir: %v", run.act.Args)
		}
	}
	wantNo := []string{
		"load-genomic", "--partition", "chr22", "--vcf-index", "/data/idx.tsv",
		"--heap", defaultGenomicHeap,
	}
	if !eq(run.act.Args, wantNo) {
		t.Errorf("dir-ask=no args = %v, want %v", run.act.Args, wantNo)
	}

	// yes → DirMode browser, vcfDir set, --vcf-dir present.
	s = newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s = driveGenomicToConfirm(t, s, genomicInputs{
		vcfIndex: "/data/idx.tsv", includeVCFDir: true, vcfDir: "/data/vcf", partition: "chr22",
	})
	if s.vcfDir != "/data/vcf" {
		t.Errorf("dir-ask=yes vcfDir=%q, want /data/vcf", s.vcfDir)
	}
	s.confirmed = true
	_, cmd = completeForm(s)
	run = cmd().(runActionMsg)
	if !containsPair(run.act.Args, "--vcf-dir", "/data/vcf") {
		t.Errorf("dir-ask=yes argv missing --vcf-dir /data/vcf: %v", run.act.Args)
	}
}

// TestLoadWizardGenomicToggles: each promote/enable-profile combination yields
// the correct presence of --promote / --enable-profile in the argv.
func TestLoadWizardGenomicToggles(t *testing.T) {
	for _, c := range []struct {
		promote, profile bool
	}{
		{false, false}, {true, false}, {false, true}, {true, true},
	} {
		s := newLoadScreen("/tmp/x")
		s.setSize(100, 35)
		s = driveGenomicToConfirm(t, s, genomicInputs{
			vcfIndex: "/data/idx.tsv", partition: "chr22",
			promote: c.promote, enableProfile: c.profile,
		})
		s.confirmed = true
		_, cmd := completeForm(s)
		args := cmd().(runActionMsg).act.Args
		if got := contains(args, "--promote"); got != c.promote {
			t.Errorf("promote=%v profile=%v: --promote present=%v, want %v (%v)", c.promote, c.profile, got, c.promote, args)
		}
		if got := contains(args, "--enable-profile"); got != c.profile {
			t.Errorf("promote=%v profile=%v: --enable-profile present=%v, want %v (%v)", c.promote, c.profile, got, c.profile, args)
		}
	}
}

// TestValidatePartition: empty and bad-char partitions are rejected; valid
// letters/digits/_/- accepted. This is the validator the partition input binds.
func TestValidatePartition(t *testing.T) {
	bad := []string{"", "  ", "chr 22", "chr/22", "chr.22", "chr*", "a b"}
	for _, v := range bad {
		if validatePartition(v) == nil {
			t.Errorf("validatePartition(%q) = nil, want error", v)
		}
	}
	good := []string{"chr22", "1000genomes", "my_partition", "data-set-1", "ABC_123-x"}
	for _, v := range good {
		if err := validatePartition(v); err != nil {
			t.Errorf("validatePartition(%q) = %v, want nil", v, err)
		}
	}
}

// TestLoadWizardGenomicConfirmCaveats: the genomic confirm summary leads with
// the action's Describe and carries both caveats; with enable-profile on and
// promote off it surfaces the prominent conditional crash-loop warning.
func TestLoadWizardGenomicConfirmCaveats(t *testing.T) {
	// Risky combo: profile on, promote off → the conditional warning.
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s = driveGenomicToConfirm(t, s, genomicInputs{
		vcfIndex: "/data/idx.tsv", partition: "chr22",
		promote: false, enableProfile: true,
	})
	view := wizardANSI.ReplaceAllString(s.view(), "")
	for _, want := range []string{
		"genomic partition", // from the action's Describe
		"backup-safe",       // promote caveat
		"WITHOUT promoting", // the prominent conditional warning
		"crash-loop",
		"chr22", "/data/idx.tsv", "(index paths)", // digest rows, no dir → index paths
	} {
		if !strings.Contains(view, want) {
			t.Errorf("genomic confirm summary missing %q:\n%s", want, view)
		}
	}

	// Safe combo: the flat (non-conditional) profile caveat is shown instead.
	s = newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s = driveGenomicToConfirm(t, s, genomicInputs{
		vcfIndex: "/data/idx.tsv", partition: "chr22",
		promote: true, enableProfile: false,
	})
	view = wizardANSI.ReplaceAllString(s.view(), "")
	if strings.Contains(view, "WITHOUT promoting") {
		t.Errorf("non-risky combo should not show the conditional warning:\n%s", view)
	}
	if !strings.Contains(view, "before genomic data is present crash-loops") {
		t.Errorf("non-risky combo missing the flat profile caveat:\n%s", view)
	}
}

// TestLoadWizardGenomicEscDirtyGuard: once the VCF index is collected, esc on
// the genomic branch raises the discard prompt rather than closing.
func TestLoadWizardGenomicEscDirtyGuard(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s.kind = "genomic"
	s, _ = completeForm(s)

	// Pristine genomic file step (no index yet) closes immediately on esc.
	s2, cmd := s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if s2.discarding {
		t.Fatal("esc before any genomic input raised the discard prompt")
	}
	if msg, ok := cmd().(loadDataClosedMsg); !ok || !msg.aborted {
		t.Fatalf("pristine genomic esc = %#v, want loadDataClosedMsg{aborted:true}", cmd())
	}

	// After the VCF index, the screen is dirty: esc raises the discard prompt.
	s = newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s.kind = "genomic"
	s, _ = completeForm(s)
	s, _ = s.consumeFile("/data/idx.tsv")
	if !s.dirty() {
		t.Fatal("screen should be dirty after the VCF index selection")
	}
	s, cmd = s.update(tea.KeyMsg{Type: tea.KeyEsc})
	if !s.discarding {
		t.Fatal("esc after vcf-index did not raise the discard prompt")
	}
	if cmd != nil {
		t.Fatal("esc on a dirty genomic screen must not close yet")
	}
	if !strings.Contains(wizardANSI.ReplaceAllString(s.view(), ""), "Discard data load?") {
		t.Errorf("footer missing the discard prompt:\n%s", wizardANSI.ReplaceAllString(s.view(), ""))
	}
}

// TestLoadWizardGenomicConfirmCancelCloses: declining the genomic confirm
// closes the screen without dispatching a load.
func TestLoadWizardGenomicConfirmCancelCloses(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	s = driveGenomicToConfirm(t, s, genomicInputs{vcfIndex: "/data/idx.tsv", partition: "chr22"})
	s.confirmed = false
	_, cmd := completeForm(s)
	if cmd == nil {
		t.Fatal("declined genomic confirm produced no command")
	}
	if msg, ok := cmd().(loadDataClosedMsg); !ok || !msg.aborted {
		t.Fatalf("declined genomic confirm = %#v, want loadDataClosedMsg{aborted:true}", cmd())
	}
}

// TestLoadWizardKindStepSingleTitle: the kind step must render the "Load your
// data" header exactly once — the form no longer carries a redundant .Title.
func TestLoadWizardKindStepSingleTitle(t *testing.T) {
	s := newLoadScreen("/tmp/x")
	s.setSize(100, 35)
	view := wizardANSI.ReplaceAllString(s.view(), "")
	if n := strings.Count(view, "Load your data"); n != 1 {
		t.Errorf("kind step renders %q %d times, want 1:\n%s", "Load your data", n, view)
	}
}

// containsPair reports whether flag is immediately followed by val in argv.
func containsPair(args []string, flag, val string) bool {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag && args[i+1] == val {
			return true
		}
	}
	return false
}
