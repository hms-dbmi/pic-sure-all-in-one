package wizard

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Drift guard: every wizard key must exist as an assignment in the real
// .env.example. Catches the wizard going stale when the config surface moves.
func TestEveryFieldKeyExistsInEnvExample(t *testing.T) {
	path := filepath.Join("..", "..", "..", ".env.example")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading repo .env.example: %v", err)
	}
	for _, f := range Fields {
		re := regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(f.Key) + `=`)
		if !re.Match(data) {
			t.Errorf("wizard field %s (%s) not found in .env.example", f.Key, f.Flag)
		}
	}
}

func TestFieldTableShape(t *testing.T) {
	seenFlags := map[string]bool{}
	for _, f := range Fields {
		if f.Flag == "" || f.Key == "" || f.Group == "" {
			t.Errorf("field %+v missing identity", f)
		}
		if seenFlags[f.Flag] {
			t.Errorf("duplicate flag %s", f.Flag)
		}
		seenFlags[f.Flag] = true
	}
}

func TestMissingRequired(t *testing.T) {
	defaults := map[string]string{
		"AUTH0_TENANT": "avillachlab",
		"HTTP_PORT":    "80",
		"HTTPS_PORT":   "443",
		"AUTH_MODE":    "required",
		"DB_MODE":      "local",
		"DB_HOST":      "picsure-db",
		"DB_PORT":      "3306",
		"DB_ROOT_USER": "root",
	}

	t.Run("fresh defaults need auth0 and admin email", func(t *testing.T) {
		got := MissingRequired(defaults, false)
		want := []string{"--auth0-client-id", "--auth0-client-secret", "--admin-email"}
		if len(got) != len(want) {
			t.Fatalf("missing = %v, want %v", got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("missing = %v, want %v", got, want)
			}
		}
	})

	t.Run("skip-auth lifts auth0 requirements but not admin email", func(t *testing.T) {
		got := MissingRequired(defaults, true)
		if len(got) != 1 || got[0] != "--admin-email" {
			t.Fatalf("missing = %v, want [--admin-email]", got)
		}
	})

	t.Run("remote db mode adds connection requirements", func(t *testing.T) {
		vals := map[string]string{}
		for k, v := range defaults {
			vals[k] = v
		}
		vals["DB_MODE"] = "remote"
		vals["DB_HOST"] = "" // remote default placeholder cleared
		vals["ADMIN_EMAIL"] = "a@b.com"
		got := MissingRequired(vals, true)
		want := map[string]bool{"--db-host": true, "--db-root-password": true}
		if len(got) != len(want) {
			t.Fatalf("missing = %v, want %v", got, want)
		}
		for _, m := range got {
			if !want[m] {
				t.Errorf("unexpected missing flag %s", m)
			}
		}
	})

	t.Run("complete set has nothing missing", func(t *testing.T) {
		vals := map[string]string{}
		for k, v := range defaults {
			vals[k] = v
		}
		vals["AUTH0_CLIENT_ID"] = "cid"
		vals["AUTH0_CLIENT_SECRET"] = "sec"
		vals["ADMIN_EMAIL"] = "admin@example.com"
		if got := MissingRequired(vals, false); len(got) != 0 {
			t.Errorf("missing = %v, want none", got)
		}
	})
}

func TestValidateAll(t *testing.T) {
	base := map[string]string{
		"AUTH0_CLIENT_ID":        "cid",
		"AUTH0_CLIENT_SECRET":    "sec",
		"ADMIN_EMAIL":            "admin@example.com",
		"HTTP_PORT":              "80",
		"HTTPS_PORT":             "443",
		"AUTH_MODE":              "required",
		"DB_MODE":                "local",
		"RELEASE_CONTROL_REPO":   "https://github.com/hms-dbmi/pic-sure-baseline-release-control",
		"RELEASE_CONTROL_BRANCH": "main",
	}
	if err := ValidateAll(base, false); err != nil {
		t.Errorf("valid set rejected: %v", err)
	}

	bad := map[string]string{}
	for k, v := range base {
		bad[k] = v
	}
	bad["ADMIN_EMAIL"] = "not-an-email"
	if err := ValidateAll(bad, false); err == nil {
		t.Error("bad email accepted")
	}

	clash := map[string]string{}
	for k, v := range base {
		clash[k] = v
	}
	clash["HTTPS_PORT"] = "80"
	if err := ValidateAll(clash, false); err == nil {
		t.Error("identical HTTP/HTTPS ports accepted")
	}
}

// The release-control fields are non-Required (defaults always present) but
// still reject an empty value if the user clears them — a blank repo or branch
// would break release-control resolution.
func TestReleaseControlFieldsRejectEmpty(t *testing.T) {
	for _, flag := range []string{"--release-control-repo", "--release-control-branch"} {
		f, ok := FieldByFlag(flag)
		if !ok {
			t.Fatalf("field for %s not found", flag)
		}
		if f.Required || f.Auth0Required || f.RequiredWhenRemote || f.RemoteOnly {
			t.Errorf("%s should be a plain non-required field, got %+v", flag, f)
		}
		if f.Validate == nil {
			t.Fatalf("%s must have a validator", flag)
		}
		if err := f.Validate("  ", nil); err == nil {
			t.Errorf("%s accepted a blank value", flag)
		}
		if err := f.Validate("main", nil); err != nil {
			t.Errorf("%s rejected a valid value: %v", flag, err)
		}
	}
}

func TestChangedKeys(t *testing.T) {
	current := map[string]string{"AUTH0_TENANT": "avillachlab", "HTTP_PORT": "80", "ADMIN_EMAIL": ""}
	desired := map[string]string{"AUTH0_TENANT": "avillachlab", "HTTP_PORT": "8080", "ADMIN_EMAIL": "a@b.com"}
	got := ChangedKeys(current, desired)
	want := []string{"ADMIN_EMAIL", "HTTP_PORT"} // table order: ADMIN_EMAIL before HTTP_PORT
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("changed = %v, want %v", got, want)
	}
}

func TestReadEnvValuesUnquoting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	content := "# comment\nAUTH0_TENANT=plain\nADMIN_EMAIL='quoted@example.com'\nDB_HOST=\"dq.example.com\"\nAUTH0_CLIENT_ID='it'\\''s'\nIGNORED_KEY=zzz\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadEnvValues(path)
	if err != nil {
		t.Fatal(err)
	}
	if got["AUTH0_TENANT"] != "plain" {
		t.Errorf("plain = %q", got["AUTH0_TENANT"])
	}
	if got["ADMIN_EMAIL"] != "quoted@example.com" {
		t.Errorf("single-quoted = %q", got["ADMIN_EMAIL"])
	}
	if got["DB_HOST"] != "dq.example.com" {
		t.Errorf("double-quoted = %q", got["DB_HOST"])
	}
	if got["AUTH0_CLIENT_ID"] != "it's" {
		t.Errorf("escaped single quote = %q", got["AUTH0_CLIENT_ID"])
	}
	if _, ok := got["IGNORED_KEY"]; ok {
		t.Error("non-wizard keys should be ignored")
	}
}

func TestReadEnvValuesExportPrefix(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	content := "export AUTH0_TENANT=exported\nexport ADMIN_EMAIL='a@b.com'\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadEnvValues(path)
	if err != nil {
		t.Fatal(err)
	}
	if got["AUTH0_TENANT"] != "exported" {
		t.Errorf("export-prefixed = %q, want exported", got["AUTH0_TENANT"])
	}
	if got["ADMIN_EMAIL"] != "a@b.com" {
		t.Errorf("export-prefixed quoted = %q", got["ADMIN_EMAIL"])
	}
}

func TestValidateProvided(t *testing.T) {
	current := map[string]string{"ADMIN_EMAIL": "not-an-email-but-preexisting", "HTTP_PORT": "80"}

	// A bad pre-existing value is NOT re-judged when the user didn't touch it.
	provided := map[string]string{"HTTPS_PORT": "443"}
	if err := ValidateProvided(provided, merge(current, provided)); err != nil {
		t.Errorf("untouched bad value was re-judged: %v", err)
	}

	// A bad provided value errors, naming its flag.
	provided = map[string]string{"ADMIN_EMAIL": "still-not-an-email"}
	err := ValidateProvided(provided, merge(current, provided))
	if err == nil || !strings.Contains(err.Error(), "--admin-email") {
		t.Errorf("ValidateProvided = %v, want --admin-email error", err)
	}

	// Cross-field validation sees the merged context: HTTPS == existing HTTP.
	provided = map[string]string{"HTTPS_PORT": "80"}
	err = ValidateProvided(provided, merge(current, provided))
	if err == nil || !strings.Contains(err.Error(), "--https-port") {
		t.Errorf("ValidateProvided = %v, want --https-port clash error", err)
	}
}

func merge(base, overlay map[string]string) map[string]string {
	out := make(map[string]string, len(base)+len(overlay))
	for k, v := range base {
		out[k] = v
	}
	for k, v := range overlay {
		out[k] = v
	}
	return out
}
