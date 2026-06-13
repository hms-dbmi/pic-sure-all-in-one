package actions

import (
	"strings"
	"testing"
)

func TestConfirmAccepted(t *testing.T) {
	plain := Update()
	destructive := Reset()
	tests := []struct {
		name string
		act  Action
		ok   bool
		text string
		want bool
	}{
		{"plain yes", plain, true, "", true},
		{"plain no", plain, false, "", false},
		{"destructive exact word", destructive, false, "reset", true},
		{"destructive padded word", destructive, false, "  reset ", true},
		{"destructive wrong word", destructive, false, "RESET", false},
		{"destructive ok flag ignored", destructive, true, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ConfirmAccepted(tt.act, tt.ok, tt.text); got != tt.want {
				t.Errorf("ConfirmAccepted = %v, want %v", got, tt.want)
			}
		})
	}
}

// ResetAll surfaces reset.sh --all (full wipe: DB volume, PIC-SURE images, and
// the Maven cache, on top of everything plain reset removes). It must pass both
// --all and --yes (the UI already confirmed), run the reset script, and gate on
// the same typed word as the DB-preserving reset.
func TestResetAllArgs(t *testing.T) {
	a := ResetAll()
	if !a.Destructive || a.ConfirmWord != "reset" {
		t.Fatalf("ResetAll must be destructive with confirm word %q, got destructive=%v word=%q",
			"reset", a.Destructive, a.ConfirmWord)
	}
	if a.Script != Reset().Script {
		t.Errorf("ResetAll must run the reset script, got %q", a.Script)
	}
	want := []string{"--all", "--yes"}
	if len(a.Args) != len(want) {
		t.Fatalf("ResetAll args = %v, want %v", a.Args, want)
	}
	for i := range want {
		if a.Args[i] != want[i] {
			t.Fatalf("ResetAll args = %v, want %v", a.Args, want)
		}
	}
}

// ResetWith parameterizes the reset action by scope (all) and the repo toggle.
// The repo toggle adds reset.sh --repos: a git-preserving working-tree reset of
// the sibling checkouts (history kept). Reset()/ResetAll() are the zero-arg
// repos-off wrappers and must equal ResetWith(false,false)/(true,false).
func TestResetWithArgs(t *testing.T) {
	eq := func(a, b []string) bool {
		if len(a) != len(b) {
			return false
		}
		for i := range a {
			if a[i] != b[i] {
				return false
			}
		}
		return true
	}
	cases := []struct {
		all, repos bool
		want       []string
	}{
		{false, false, []string{"--yes"}},
		{true, false, []string{"--all", "--yes"}},
		{false, true, []string{"--repos", "--yes"}},
		{true, true, []string{"--all", "--repos", "--yes"}},
	}
	for _, c := range cases {
		a := ResetWith(c.all, c.repos)
		if a.Script != Reset().Script {
			t.Errorf("ResetWith(%v,%v) must run the reset script, got %q", c.all, c.repos, a.Script)
		}
		if !a.Destructive || a.ConfirmWord != "reset" {
			t.Errorf("ResetWith(%v,%v) must be destructive with word %q", c.all, c.repos, "reset")
		}
		if !eq(a.Args, c.want) {
			t.Errorf("ResetWith(%v,%v) args = %v, want %v", c.all, c.repos, a.Args, c.want)
		}
	}

	// Zero-arg wrappers are exactly the repos-off variants.
	if !eq(Reset().Args, ResetWith(false, false).Args) {
		t.Errorf("Reset() = %v, want ResetWith(false,false) = %v", Reset().Args, ResetWith(false, false).Args)
	}
	if !eq(ResetAll().Args, ResetWith(true, false).Args) {
		t.Errorf("ResetAll() = %v, want ResetWith(true,false) = %v", ResetAll().Args, ResetWith(true, false).Args)
	}

	// The repo toggle surfaces the history-kept reassurance, and the
	// "repos are kept" sentence must flip with it — claiming both "repos are
	// kept" and "repos are reset" in one dialog was a bug.
	for _, all := range []bool{false, true} {
		on := ResetWith(all, true).Describe
		for _, want := range []string{"Sibling repos are reset to their release refs", "git history are KEPT"} {
			if !strings.Contains(on, want) {
				t.Errorf("ResetWith(%v,true).Describe missing %q:\n%s", all, want, on)
			}
		}
		if strings.Contains(on, "Sibling repos and .env.example are kept") {
			t.Errorf("ResetWith(%v,true).Describe still claims repos are kept:\n%s", all, on)
		}
		off := ResetWith(all, false).Describe
		if !strings.Contains(off, "Sibling repos and .env.example are kept") {
			t.Errorf("ResetWith(%v,false).Describe missing the repos-kept sentence:\n%s", all, off)
		}
		if strings.Contains(off, "are reset to their release refs") {
			t.Errorf("ResetWith(%v,false).Describe mentions a repo reset it will not do:\n%s", all, off)
		}
	}
}

// Spec amendment 3: no abort may leave the user guessing about state. Every
// action must carry a one-line post-abort re-run-safety note.
func TestEveryActionHasAbortNote(t *testing.T) {
	acts := []Action{
		Init(), Update(), Restart("wildfly"), Preflight(), Migrate(), SeedDB(),
		DemoData("nhanes"), DemoData("all"), DevUp("httpd-hmr"), DevOff("httpd"),
		Reset(), ResetAll(), ResetWith(false, true), ResetWith(true, true), Uninstall(),
		Etl("hydrate-dictionary"), Etl("run-weights"), Etl("promote-genomic"), Etl("public-1000genomes"),
		ReleaseControlApply(), ReleaseControlDryRun(), ReleaseControlBranch("main"),
		LoadPhenotype(PhenotypeOpts{File: "data.csv"}),
		LoadPhenotype(PhenotypeOpts{File: "data.csv", CustomDictionary: true, Datasets: "d.csv", Concepts: "c.zip"}),
		LoadGenomic(GenomicOpts{Partition: "p", VCFIndex: "idx.tsv"}),
		LoadGenomic(GenomicOpts{Partition: "p", VCFIndex: "idx.tsv", Promote: true, EnableProfile: true}),
	}
	for _, a := range acts {
		if a.AbortNote == "" {
			t.Errorf("action %q has no AbortNote", a.Name)
		}
		if a.Describe == "" {
			t.Errorf("action %q has no Describe", a.Name)
		}
	}
}

// ---------------------------------------------------------------------------
// LoadPhenotype argv tests
// ---------------------------------------------------------------------------

func argsEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestLoadPhenotypeArgs(t *testing.T) {
	cases := []struct {
		name string
		opts PhenotypeOpts
		want []string
	}{
		{
			name: "auto minimal",
			opts: PhenotypeOpts{File: "pheno.csv"},
			want: []string{"load-phenotype", "--file", "pheno.csv"},
		},
		{
			name: "auto with heap",
			opts: PhenotypeOpts{File: "pheno.csv", Heap: "16g"},
			want: []string{"load-phenotype", "--file", "pheno.csv", "--heap", "16g"},
		},
		{
			name: "custom with facets",
			opts: PhenotypeOpts{
				File:             "pheno.csv",
				CustomDictionary: true,
				Datasets:         "datasets.csv",
				Concepts:         "concepts.zip",
				FacetCategories:  "facet-cats.csv",
				Facets:           "facets.csv",
				FacetConcepts:    "facet-concepts.csv",
			},
			want: []string{
				"load-phenotype", "--file", "pheno.csv",
				"--dictionary", "custom",
				"--datasets", "datasets.csv",
				"--concepts", "concepts.zip",
				"--facets-categories", "facet-cats.csv",
				"--facets", "facets.csv",
				"--facet-concepts", "facet-concepts.csv",
			},
		},
		{
			name: "custom without facets",
			opts: PhenotypeOpts{
				File:             "pheno.csv",
				CustomDictionary: true,
				Datasets:         "datasets.csv",
				Concepts:         "concepts.zip",
			},
			want: []string{
				"load-phenotype", "--file", "pheno.csv",
				"--dictionary", "custom",
				"--datasets", "datasets.csv",
				"--concepts", "concepts.zip",
			},
		},
		{
			name: "auto skip-weights",
			opts: PhenotypeOpts{File: "pheno.csv", SkipWeights: true},
			want: []string{"load-phenotype", "--file", "pheno.csv", "--skip-weights"},
		},
		{
			// ArchiveEntry forwards --entry after --heap (the documented
			// load-phenotype flag order), selecting one CSV from a multi-CSV tar.
			name: "archive entry",
			opts: PhenotypeOpts{File: "pheno.tgz", Heap: "4096", ArchiveEntry: "sub/dataA.csv"},
			want: []string{"load-phenotype", "--file", "pheno.tgz", "--heap", "4096", "--entry", "sub/dataA.csv"},
		},
		{
			// Empty ArchiveEntry must emit no --entry (single-CSV tar / plain gzip
			// auto-handled by etl.sh).
			name: "empty archive entry omits flag",
			opts: PhenotypeOpts{File: "pheno.gz", Heap: "4096"},
			want: []string{"load-phenotype", "--file", "pheno.gz", "--heap", "4096"},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := LoadPhenotype(c.opts)
			if a.Script != Etl("load-phenotype").Script {
				t.Errorf("Script = %q, want etl script", a.Script)
			}
			if !argsEqual(a.Args, c.want) {
				t.Errorf("Args =\n  %v\nwant\n  %v", a.Args, c.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// LoadGenomic argv tests
// ---------------------------------------------------------------------------

func TestLoadGenomicArgs(t *testing.T) {
	base := []string{"load-genomic", "--partition", "chr22", "--vcf-index", "idx.tsv"}

	cases := []struct {
		name string
		opts GenomicOpts
		want []string
	}{
		{
			name: "minimal",
			opts: GenomicOpts{Partition: "chr22", VCFIndex: "idx.tsv"},
			want: base,
		},
		{
			name: "with vcf-dir",
			opts: GenomicOpts{Partition: "chr22", VCFIndex: "idx.tsv", VCFDir: "/data/vcf"},
			want: append(append([]string{}, base...), "--vcf-dir", "/data/vcf"),
		},
		{
			name: "with heap",
			opts: GenomicOpts{Partition: "chr22", VCFIndex: "idx.tsv", Heap: "32g"},
			want: append(append([]string{}, base...), "--heap", "32g"),
		},
		{
			name: "promote",
			opts: GenomicOpts{Partition: "chr22", VCFIndex: "idx.tsv", Promote: true},
			want: append(append([]string{}, base...), "--promote"),
		},
		{
			name: "enable-profile",
			opts: GenomicOpts{Partition: "chr22", VCFIndex: "idx.tsv", EnableProfile: true},
			want: append(append([]string{}, base...), "--enable-profile"),
		},
		{
			name: "all toggles",
			opts: GenomicOpts{
				Partition:     "chr22",
				VCFIndex:      "idx.tsv",
				VCFDir:        "/data/vcf",
				Heap:          "32g",
				Promote:       true,
				EnableProfile: true,
			},
			want: []string{
				"load-genomic", "--partition", "chr22", "--vcf-index", "idx.tsv",
				"--vcf-dir", "/data/vcf",
				"--heap", "32g",
				"--promote",
				"--enable-profile",
			},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := LoadGenomic(c.opts)
			if a.Script != Etl("load-genomic").Script {
				t.Errorf("Script = %q, want etl script", a.Script)
			}
			if !argsEqual(a.Args, c.want) {
				t.Errorf("Args =\n  %v\nwant\n  %v", a.Args, c.want)
			}
		})
	}
}
