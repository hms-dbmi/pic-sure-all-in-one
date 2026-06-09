package wizard

import "testing"

// Amendment 1 (spec): exactly one form definition serves both hosts. This
// extends the .env.example drift-guard: NewForm must bind every key in the
// field table, seeded from initial — so any host built on NewForm gets the
// complete, identical wizard.
func TestNewFormBindsEveryFieldKey(t *testing.T) {
	initial := map[string]string{}
	for _, f := range Fields {
		initial[f.Key] = f.Key + "-seed" // distinct value per key
	}
	wf := NewForm(initial, false)

	desired := wf.Desired()
	if len(desired) != len(Fields) {
		t.Fatalf("Desired has %d keys, want %d (one per field)", len(desired), len(Fields))
	}
	for _, f := range Fields {
		if desired[f.Key] != initial[f.Key] {
			t.Errorf("%s = %q, want seeded %q (initial values must round-trip)", f.Key, desired[f.Key], initial[f.Key])
		}
	}
}

func TestNewFormSkipAuthSeedAndConfirm(t *testing.T) {
	wf := NewForm(map[string]string{"DB_MODE": "local"}, true)
	if !wf.SkipAuth() {
		t.Error("skipAuth seed not honored")
	}
	if wf.Confirmed() {
		t.Error("Confirmed must start false")
	}
	if wf.Main == nil {
		t.Fatal("Main form not built")
	}
	if c := wf.BuildConfirm(); c == nil || wf.Confirm == nil {
		t.Fatal("BuildConfirm did not build the confirm form")
	}
}

// Host-2 contract: a host that never calls Run() must still observe user
// edits after BuildConfirm — the sync lives there, not in RunForm.
func TestBuildConfirmSyncsEditsForEmbeddedHost(t *testing.T) {
	wf := NewForm(map[string]string{"ADMIN_EMAIL": "seed@example.com"}, false)
	// Simulate the user editing the field through huh's bound pointer.
	*wf.ptrs["ADMIN_EMAIL"] = "edited@example.com"
	wf.BuildConfirm()
	if got := wf.Desired()["ADMIN_EMAIL"]; got != "edited@example.com" {
		t.Fatalf("Desired after BuildConfirm = %q, want the user's edit", got)
	}
}
