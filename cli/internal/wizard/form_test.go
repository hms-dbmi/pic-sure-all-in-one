package wizard

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

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

// Release-control repo/branch are ordinary non-Required fields: they seed from
// the supplied defaults (in practice .env.example), round-trip through the
// form, and appear in the confirm summary (which auto-includes every applicable
// field). This is the wizard-side guarantee that init now asks for them.
func TestReleaseControlFieldsSeedAndSummarize(t *testing.T) {
	initial := map[string]string{
		"DB_MODE":                "local",
		"RELEASE_CONTROL_REPO":   "https://github.com/hms-dbmi/pic-sure-baseline-release-control",
		"RELEASE_CONTROL_BRANCH": "main",
	}
	wf := NewForm(initial, true) // skipAuth: keep the summary focused on shown fields

	desired := wf.Desired()
	if got := desired["RELEASE_CONTROL_REPO"]; got != initial["RELEASE_CONTROL_REPO"] {
		t.Errorf("RELEASE_CONTROL_REPO = %q, want seeded default", got)
	}
	if got := desired["RELEASE_CONTROL_BRANCH"]; got != "main" {
		t.Errorf("RELEASE_CONTROL_BRANCH = %q, want seeded default main", got)
	}

	// The confirm summary auto-includes both (non-secret, non-RemoteOnly).
	snap := make(map[string]*string, len(desired))
	for k := range desired {
		v := desired[k]
		snap[k] = &v
	}
	s := ansi.Strip(summary(snap, desired, true))
	for _, want := range []string{
		"Release-control repository", "https://github.com/hms-dbmi/pic-sure-baseline-release-control",
		"Release-control branch or tag", "main",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("summary missing %q\n--- summary ---\n%s", want, s)
		}
	}
	// These values equal the seeded defaults, so each carries a "(default)" mark.
	if strings.Count(s, "(default)") < 2 {
		t.Errorf("expected (default) markers on the unchanged release-control fields\n%s", s)
	}
}

// summaryFor is a test helper: build the field-value snapshot the confirm
// summary consumes from a desired map, with the given seed and skip flag.
func summaryFor(desired, seed map[string]string, skip bool) string {
	snap := make(map[string]*string, len(desired))
	for k := range desired {
		v := desired[k]
		snap[k] = &v
	}
	return summary(snap, seed, skip)
}

// TestSummaryAlignment (U8): titles pad to a common column so values line up,
// using spaces (no dot leaders) — assert every value starts at the same column.
func TestSummaryAlignment(t *testing.T) {
	desired := map[string]string{
		"DB_MODE":                "local",
		"ADMIN_EMAIL":            "admin@example.com",
		"HTTP_PORT":              "80",
		"AUTH_MODE":              "required",
		"RELEASE_CONTROL_REPO":   "https://example.com/r",
		"RELEASE_CONTROL_BRANCH": "main",
	}
	out := ansi.Strip(summaryFor(desired, map[string]string{}, true))

	// Each rendered line is "Title<pad>  value[ (default)]". The value column
	// must be identical across lines: find the index where the two-space gap
	// after the longest title ends.
	lines := strings.Split(out, "\n")
	valueCol := -1
	for _, line := range lines {
		if strings.HasPrefix(line, "Identity provider:") {
			continue // the IdP preamble is not a padded field row
		}
		// The value starts after the run of trailing title-pad spaces; locate
		// the "  " (two-space) separator that precedes it.
		idx := strings.Index(line, "  ")
		if idx < 0 {
			t.Fatalf("no aligned gap in line %q", line)
		}
		// Skip past all spaces to the value's first non-space char.
		col := idx
		for col < len(line) && line[col] == ' ' {
			col++
		}
		if valueCol == -1 {
			valueCol = col
		} else if col != valueCol {
			t.Errorf("value column not aligned: %d vs %d in %q", col, valueCol, line)
		}
	}
	if valueCol < 0 {
		t.Fatal("no field rows rendered")
	}
}

// TestSummaryOmitsEmptyOptional (U8): an optional field left empty is dropped
// entirely (no "(empty)"), while a required field left empty is still surfaced.
func TestSummaryOmitsEmptyOptional(t *testing.T) {
	// AUTH0_TENANT is optional (no Required/Auth0Required); ADMIN_EMAIL is
	// always required. DB_ROOT_USER is optional and remote-only.
	desired := map[string]string{
		"DB_MODE":      "local",
		"AUTH0_TENANT": "", // optional, empty → omitted
		"ADMIN_EMAIL":  "", // required, empty → surfaced as (empty)
		"HTTP_PORT":    "80",
	}
	out := ansi.Strip(summaryFor(desired, map[string]string{}, true))

	if strings.Contains(out, "Auth0 tenant") {
		t.Errorf("empty optional Auth0 tenant should be omitted:\n%s", out)
	}
	if !strings.Contains(out, "Admin email") || !strings.Contains(out, "(empty)") {
		t.Errorf("empty required Admin email should be surfaced as (empty):\n%s", out)
	}
}

// TestSummaryDefaultMarker (U8): a field whose value equals the seeded default
// gets a "(default)" marker; an edited field does not.
func TestSummaryDefaultMarker(t *testing.T) {
	seed := map[string]string{
		"DB_MODE":      "local",
		"AUTH_MODE":    "required",
		"HTTP_PORT":    "80",
		"AUTH0_TENANT": "avillachlab",
	}
	desired := map[string]string{
		"DB_MODE":      "local",       // unchanged → (default)
		"AUTH_MODE":    "open",        // edited → no marker
		"HTTP_PORT":    "80",          // unchanged → (default)
		"AUTH0_TENANT": "avillachlab", // unchanged → (default)
	}
	out := ansi.Strip(summaryFor(desired, seed, true))

	lineFor := func(title string) string {
		for _, l := range strings.Split(out, "\n") {
			if strings.HasPrefix(l, title) {
				return l
			}
		}
		return ""
	}
	if l := lineFor("Database mode"); !strings.Contains(l, "(default)") {
		t.Errorf("unchanged Database mode should be marked (default): %q", l)
	}
	if l := lineFor("Auth mode"); strings.Contains(l, "(default)") {
		t.Errorf("edited Auth mode should NOT be marked (default): %q", l)
	}
	if l := lineFor("HTTP port"); !strings.Contains(l, "(default)") {
		t.Errorf("unchanged HTTP port should be marked (default): %q", l)
	}
}

// TestSummaryNoDotLeaders (U8): alignment uses spaces, not dot leaders.
func TestSummaryNoDotLeaders(t *testing.T) {
	desired := map[string]string{"DB_MODE": "local", "HTTP_PORT": "80", "ADMIN_EMAIL": "a@b.com"}
	out := ansi.Strip(summaryFor(desired, map[string]string{}, true))
	if strings.Contains(out, "..") || strings.Contains(out, ". .") {
		t.Errorf("summary should not use dot leaders:\n%s", out)
	}
}

// TestGroupIntrosRender: every field section carries a one-sentence intro
// (group Title + Description) so the wizard reads as a guided flow rather than a
// flat wall. The first group's header is asserted through a live huh render
// (proving the mechanism), and every group's header is checked via Group.Header
// (huh renders Title+Description there regardless of focus).
func TestGroupIntrosRender(t *testing.T) {
	wf := NewForm(map[string]string{"DB_MODE": "local"}, false)

	// Live render of the focused (first) group shows its intro through huh.
	wf.Main.Init()
	first := ansi.Strip(wf.Main.View())
	if !strings.Contains(first, "Choose how users sign in") {
		t.Errorf("first group's intro did not render in the live form view:\n%s", first)
	}

	// Every section's intro sentence appears in some group header. A group is
	// the conditionally-hidden remote-DB group or the always-shown rest; either
	// way Header() renders the Title+Description.
	headers := make([]string, 0, len(wf.groups))
	for _, g := range wf.groups {
		headers = append(headers, ansi.Strip(g.Header()))
	}
	joined := strings.Join(headers, "\n----\n")

	wantIntros := []string{
		"Choose how users sign in",                              // Identity provider
		"From your Auth0 application",                           // Auth0 credentials
		"The first administrator",                               // Admin account
		"Host ports the frontend binds",                         // Ports
		"How much of PIC-SURE is reachable without signing in",  // Access control
		"Local runs a bundled MySQL; remote points at your own", // Database
		"Where to reach your external MySQL",                    // Remote database connection
		"Pins which component versions are built",               // Release control
	}
	for _, want := range wantIntros {
		if !strings.Contains(joined, want) {
			t.Errorf("no group header contains the intro %q\n--- headers ---\n%s", want, joined)
		}
	}

	// Regression guard: a group's title must not reappear as a field title
	// directly beneath its header — the IdP select used to repeat "Identity
	// provider" (and the Auth mode group its single field's title), which read
	// doubled when rendered. Compare whole trimmed lines so e.g. the "Database"
	// title cannot false-positive against the "Database mode" field.
	if c := strings.Count(first, "Identity provider"); c != 1 {
		t.Errorf("live render shows %d \"Identity provider\" titles, want exactly 1:\n%s", c, first)
	}
	for i, g := range wf.groups {
		title := strings.TrimSpace(strings.SplitN(ansi.Strip(g.Header()), "\n", 2)[0])
		if title == "" {
			continue
		}
		for _, raw := range strings.Split(ansi.Strip(g.Content()), "\n") {
			line := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(raw), "┃"))
			if line == title {
				t.Errorf("group %d: title %q repeats as a field line right under the header — reads doubled", i, title)
			}
		}
	}
}

// Dirty drives the embedded host's esc-discard guard: pristine seeds report
// clean, a field edit or an IdP-selector flip reports dirty. The baseline is
// captured post-construction so huh's select normalisation never reads as a
// phantom edit on first open.
func TestFormDirty(t *testing.T) {
	wf := NewForm(map[string]string{"ADMIN_EMAIL": "seed@example.com", "DB_MODE": "local"}, false)
	if wf.Dirty() {
		t.Fatal("a freshly seeded form must be pristine")
	}

	*wf.ptrs["ADMIN_EMAIL"] = "edited@example.com"
	if !wf.Dirty() {
		t.Fatal("a field edit must read as dirty")
	}
	*wf.ptrs["ADMIN_EMAIL"] = "seed@example.com"
	if wf.Dirty() {
		t.Fatal("reverting the edit must read as pristine again")
	}

	// The IdP selector is also part of the baseline.
	wf.skip = !wf.skip
	if !wf.Dirty() {
		t.Fatal("flipping the IdP selector must read as dirty")
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
