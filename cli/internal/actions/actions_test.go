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

// Spec amendment 3: no abort may leave the user guessing about state. Every
// action must carry a one-line post-abort re-run-safety note.
func TestEveryActionHasAbortNote(t *testing.T) {
	acts := []Action{
		Init(), Update(), Restart("wildfly"), Preflight(), Migrate(), SeedDB(),
		DemoData("nhanes"), DemoData("all"), DevUp("httpd-hmr"), DevOff("httpd"), Reset(), Uninstall(),
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
