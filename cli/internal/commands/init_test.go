package commands

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseInitArgs(t *testing.T) {
	tests := []struct {
		name       string
		in         []string
		wantFields map[string]string
		wantPass   []string
		wantWizard bool
		wantSkip   bool
		wantErr    bool
	}{
		{
			name:       "field flags in both forms",
			in:         []string{"--auth0-client-id", "cid", "--admin-email=a@b.com", "--force"},
			wantFields: map[string]string{"AUTH0_CLIENT_ID": "cid", "ADMIN_EMAIL": "a@b.com"},
			wantPass:   []string{"--force"},
		},
		{
			name:       "wizard and skip-auth consumed",
			in:         []string{"--wizard", "--skip-auth", "--verbose"},
			wantFields: map[string]string{},
			wantPass:   []string{"--verbose"},
			wantWizard: true,
			wantSkip:   true,
		},
		{
			name:       "init.sh flags pass through verbatim incl equals form",
			in:         []string{"--release-control-branch=release/2.4", "--log"},
			wantFields: map[string]string{},
			wantPass:   []string{"--release-control-branch=release/2.4", "--log"},
		},
		{
			name:    "field flag without value errors",
			in:      []string{"--auth0-client-id"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseInitArgs(tt.in)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got.FieldValues, tt.wantFields) {
				t.Errorf("fields = %v, want %v", got.FieldValues, tt.wantFields)
			}
			if !reflect.DeepEqual(got.Passthrough, tt.wantPass) {
				t.Errorf("passthrough = %v, want %v", got.Passthrough, tt.wantPass)
			}
			if got.Wizard != tt.wantWizard || got.SkipAuth != tt.wantSkip {
				t.Errorf("wizard=%v skip=%v, want %v/%v", got.Wizard, got.SkipAuth, tt.wantWizard, tt.wantSkip)
			}
		})
	}
}

// scriptCall records one runScript/runScriptInput invocation.
type scriptCall struct {
	script string
	args   []string
	input  string // stdin payload for runScriptInput calls
}

// fakeApp builds an app whose script runs are recorded instead of executed.
// env-set.sh calls simulate the real script's create-from-example behavior
// so later stat checks behave realistically.
func fakeApp(t *testing.T, root string, interactive bool) (*app, *[]scriptCall) {
	t.Helper()
	calls := &[]scriptCall{}
	a := &app{
		findRoot:      func(start, override string) (string, error) { return root, nil },
		isInteractive: func() bool { return interactive },
	}
	record := func(r, script string, args []string, input string) (int, error) {
		*calls = append(*calls, scriptCall{script, args, input})
		if script == "scripts/env-set.sh" {
			envPath := filepath.Join(r, ".env")
			if _, err := os.Stat(envPath); err != nil {
				data, err := os.ReadFile(filepath.Join(r, ".env.example"))
				if err != nil {
					return 2, nil
				}
				if err := os.WriteFile(envPath, data, 0o644); err != nil {
					return 2, nil
				}
			}
		}
		return 0, nil
	}
	a.runScript = func(r, script string, args []string) (int, error) {
		return record(r, script, args, "")
	}
	a.runScriptInput = func(r, script string, args []string, input string) (int, error) {
		return record(r, script, args, input)
	}
	return a, calls
}

// initFixtureRoot creates a temp checkout root with a realistic .env.example.
func initFixtureRoot(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	example := `AUTH0_CLIENT_ID=
AUTH0_CLIENT_SECRET=
AUTH0_TENANT=avillachlab
ADMIN_EMAIL=
HTTP_PORT=80
HTTPS_PORT=443
AUTH_MODE=required
DB_MODE=local
DB_HOST=picsure-db
DB_PORT=3306
DB_ROOT_USER=root
DB_ROOT_PASSWORD=
`
	if err := os.WriteFile(filepath.Join(dir, ".env.example"), []byte(example), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "docker-compose.yml"), []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "scripts", "picsure-compose.sh"), []byte("# marker\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func envSetCalls(calls []scriptCall) []scriptCall {
	var out []scriptCall
	for _, c := range calls {
		if c.script == "scripts/env-set.sh" {
			out = append(out, c)
		}
	}
	return out
}

func TestInitNonInteractiveAllFlags(t *testing.T) {
	root := initFixtureRoot(t)
	a, calls := fakeApp(t, root, false)

	err := a.runInit([]string{
		"--auth0-client-id", "cid",
		"--auth0-client-secret", "sec",
		"--admin-email", "admin@example.com",
		"--force",
	})
	if err != nil {
		t.Fatal(err)
	}

	sets := envSetCalls(*calls)
	if len(sets) != 3 {
		t.Fatalf("env-set calls = %v, want 3", sets)
	}
	for _, c := range sets {
		switch c.args[0] {
		case "AUTH0_CLIENT_ID":
			// Plain values go KEY -- VALUE so a value beginning with `--`
			// reaches env-set.sh as a value, not an option (B20).
			if len(c.args) != 3 || c.args[1] != "--" || c.args[2] != "cid" {
				t.Errorf("env-set %v unexpected, want [AUTH0_CLIENT_ID -- cid]", c.args)
			}
		case "ADMIN_EMAIL":
			if len(c.args) != 3 || c.args[1] != "--" || c.args[2] != "admin@example.com" {
				t.Errorf("env-set %v unexpected, want [ADMIN_EMAIL -- admin@example.com]", c.args)
			}
		case "AUTH0_CLIENT_SECRET":
			// Secrets must never appear in argv: --stdin with the value
			// delivered on stdin.
			if c.args[1] != "--stdin" || c.input != "sec" {
				t.Errorf("secret write = %+v, want [AUTH0_CLIENT_SECRET --stdin] with stdin payload", c)
			}
		default:
			t.Errorf("unexpected env-set key %s", c.args[0])
		}
	}

	last := (*calls)[len(*calls)-1]
	if last.script != "init.sh" || !reflect.DeepEqual(last.args, []string{"--force"}) {
		t.Errorf("final call = %+v, want init.sh [--force]", last)
	}
}

func TestInitNonInteractiveSkipAuth(t *testing.T) {
	root := initFixtureRoot(t)
	a, calls := fakeApp(t, root, false)

	err := a.runInit([]string{"--skip-auth", "--admin-email", "admin@example.com"})
	if err != nil {
		t.Fatal(err)
	}
	sets := envSetCalls(*calls)
	if len(sets) != 1 || sets[0].args[0] != "ADMIN_EMAIL" {
		t.Errorf("env-set calls = %v, want only ADMIN_EMAIL", sets)
	}
}

func TestInitNonInteractiveMissingFlagsNamesThem(t *testing.T) {
	root := initFixtureRoot(t)
	a, _ := fakeApp(t, root, false)

	err := a.runInit([]string{"--admin-email", "admin@example.com"})
	if err == nil {
		t.Fatal("expected refusal")
	}
	for _, want := range []string{"--auth0-client-id", "--auth0-client-secret", "--skip-auth"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should mention %s, got: %v", want, err)
		}
	}
}

func TestInitNonInteractiveRemoteDBRequiresConnection(t *testing.T) {
	root := initFixtureRoot(t)
	a, _ := fakeApp(t, root, false)

	err := a.runInit([]string{"--skip-auth", "--admin-email", "a@b.com", "--db-mode", "remote", "--db-host", ""})
	if err == nil {
		t.Fatal("expected refusal for missing remote DB fields")
	}
	if !strings.Contains(err.Error(), "--db-host") && !strings.Contains(err.Error(), "--db-root-password") {
		t.Errorf("error should mention remote db flags, got: %v", err)
	}
}

func TestInitExistingEnvNoWizardRunsInitDirectly(t *testing.T) {
	root := initFixtureRoot(t)
	// .env exists with empty AUTH0 values — must NOT trigger the wizard or
	// any writes (init.sh's warn-and-proceed is intentional).
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte("AUTH0_CLIENT_ID=\nDB_MODE=local\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a, calls := fakeApp(t, root, true) // even on a TTY

	if err := a.runInit([]string{"--verbose"}); err != nil {
		t.Fatal(err)
	}
	if len(*calls) != 1 {
		t.Fatalf("calls = %+v, want only init.sh", *calls)
	}
	if (*calls)[0].script != "init.sh" || !reflect.DeepEqual((*calls)[0].args, []string{"--verbose"}) {
		t.Errorf("call = %+v", (*calls)[0])
	}
}

func TestInitExistingEnvFieldFlagsWriteOnlyChanged(t *testing.T) {
	root := initFixtureRoot(t)
	envContent := "AUTH0_CLIENT_ID=cid\nAUTH0_TENANT=avillachlab\nADMIN_EMAIL=old@example.com\nHTTP_PORT=80\n"
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte(envContent), 0o644); err != nil {
		t.Fatal(err)
	}
	a, calls := fakeApp(t, root, false)

	// Same tenant (unchanged → no write), new admin email (changed → write).
	err := a.runInit([]string{"--auth0-tenant", "avillachlab", "--admin-email", "new@example.com"})
	if err != nil {
		t.Fatal(err)
	}
	sets := envSetCalls(*calls)
	if len(sets) != 1 || sets[0].args[0] != "ADMIN_EMAIL" ||
		len(sets[0].args) != 3 || sets[0].args[1] != "--" || sets[0].args[2] != "new@example.com" {
		t.Errorf("env-set calls = %v, want only changed ADMIN_EMAIL via [ADMIN_EMAIL -- new@example.com]", sets)
	}
}

func TestInitWizardFlagNonTTYFails(t *testing.T) {
	root := initFixtureRoot(t)
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte("DB_MODE=local\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a, _ := fakeApp(t, root, false)

	err := a.runInit([]string{"--wizard"})
	if err == nil || !strings.Contains(err.Error(), "terminal") {
		t.Fatalf("expected terminal error, got: %v", err)
	}
}

func TestInitSkipAuthDefaultsStillCreatesEnv(t *testing.T) {
	root := initFixtureRoot(t)
	a, calls := fakeApp(t, root, false)

	// Nothing differs from the template except admin email is required.
	err := a.runInit([]string{"--skip-auth", "--admin-email", "a@b.com"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, ".env")); err != nil {
		t.Error(".env should exist before init.sh runs")
	}
	last := (*calls)[len(*calls)-1]
	if last.script != "init.sh" {
		t.Errorf("last call = %+v, want init.sh", last)
	}
}

func TestInitExistingEnvRejectsInvalidFieldFlags(t *testing.T) {
	root := initFixtureRoot(t)
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte("ADMIN_EMAIL=ok@example.com\nHTTP_PORT=80\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a, calls := fakeApp(t, root, false)

	err := a.runInit([]string{"--admin-email", "not-an-email"})
	if err == nil || !strings.Contains(err.Error(), "--admin-email") {
		t.Fatalf("runInit = %v, want validation error naming --admin-email", err)
	}
	if len(*calls) != 0 {
		t.Errorf("calls = %+v, want none (nothing written, init.sh not run)", *calls)
	}

	// Cross-field: new HTTPS port clashing with the existing HTTP port.
	a, calls = fakeApp(t, root, false)
	err = a.runInit([]string{"--https-port", "80"})
	if err == nil || !strings.Contains(err.Error(), "--https-port") {
		t.Fatalf("runInit = %v, want clash error naming --https-port", err)
	}
	if len(*calls) != 0 {
		t.Errorf("calls = %+v, want none", *calls)
	}
}

func TestInitGlobalYesSuppressesWizardOnTTY(t *testing.T) {
	root := initFixtureRoot(t) // no .env → wizard territory
	a, calls := fakeApp(t, root, true)
	a.opts.Yes = true // --yes/--non-interactive promises "never prompt"

	err := a.runInit(nil)
	if err == nil || !strings.Contains(err.Error(), "--admin-email") {
		t.Fatalf("runInit = %v, want missing-flags error instead of a wizard prompt", err)
	}
	if len(*calls) != 0 {
		t.Errorf("calls = %+v, want none", *calls)
	}

	// --wizard combined with --yes is a contradiction, not a prompt.
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte("DB_MODE=local\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a, _ = fakeApp(t, root, true)
	a.opts.Yes = true
	err = a.runInit([]string{"--wizard"})
	if err == nil || !strings.Contains(err.Error(), "terminal") {
		t.Fatalf("runInit --wizard with --yes = %v, want refusal", err)
	}
}
