package actions

import "testing"

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

// Spec amendment 3: no abort may leave the user guessing about state. Every
// action must carry a one-line post-abort re-run-safety note.
func TestEveryActionHasAbortNote(t *testing.T) {
	acts := []Action{
		Init(), Update(), Restart("wildfly"), Preflight(), Migrate(), SeedDB(),
		DemoData("nhanes"), DemoData("all"), DevUp("httpd-hmr"), DevOff("httpd"), Reset(), ResetAll(), Uninstall(),
		Etl("hydrate-dictionary"), Etl("run-weights"), Etl("promote-genomic"), Etl("public-1000genomes"),
		ReleaseControlApply(), ReleaseControlDryRun(), ReleaseControlBranch("main"),
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
