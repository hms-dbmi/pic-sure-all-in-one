package wizard

import (
	"strings"
	"testing"
)

type recordedCall struct {
	script string
	args   []string
	input  string
}

func TestWriteChangedWritesOnlyChangedKeysSecretsViaStdin(t *testing.T) {
	var calls []recordedCall
	run := func(root, script string, args []string) (int, error) {
		calls = append(calls, recordedCall{script, args, ""})
		return 0, nil
	}
	runInput := func(root, script string, args []string, input string) (int, error) {
		calls = append(calls, recordedCall{script, args, input})
		return 0, nil
	}

	current := map[string]string{
		"ADMIN_EMAIL":         "old@example.com",
		"AUTH0_CLIENT_SECRET": "",
		"HTTP_PORT":           "80",
	}
	desired := map[string]string{
		"ADMIN_EMAIL":         "new@example.com", // changed → plain write
		"AUTH0_CLIENT_SECRET": "s3cret",          // changed secret → --stdin
		"HTTP_PORT":           "80",              // unchanged → no write
	}

	if err := WriteChanged(run, runInput, "/root", current, desired); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 {
		t.Fatalf("calls = %+v, want exactly the two changed keys", calls)
	}
	for _, c := range calls {
		if c.script != "scripts/env-set.sh" {
			t.Errorf("script = %q, want scripts/env-set.sh", c.script)
		}
		switch c.args[0] {
		case "ADMIN_EMAIL":
			// Plain writes go KEY -- VALUE: the `--` barrier lets a value
			// beginning with `--` reach env-set.sh as a value, not an option.
			if len(c.args) != 3 || c.args[1] != "--" || c.args[2] != "new@example.com" || c.input != "" {
				t.Errorf("plain write = %+v, want [KEY -- VALUE]", c)
			}
		case "AUTH0_CLIENT_SECRET":
			if c.args[1] != "--stdin" || c.input != "s3cret" {
				t.Errorf("secret must go via --stdin with the value on stdin, got %+v", c)
			}
			for _, a := range c.args {
				if a == "s3cret" {
					t.Error("secret leaked into argv")
				}
			}
		default:
			t.Errorf("unexpected key written: %v", c.args)
		}
	}
}

func TestWriteChangedSurfacesNonzeroExit(t *testing.T) {
	run := func(root, script string, args []string) (int, error) { return 2, nil }
	runInput := func(root, script string, args []string, input string) (int, error) { return 0, nil }
	err := WriteChanged(run, runInput, "/root",
		map[string]string{"ADMIN_EMAIL": "a@b.c"},
		map[string]string{"ADMIN_EMAIL": "x@y.z"})
	if err == nil || !strings.Contains(err.Error(), "exited 2") {
		t.Fatalf("err = %v, want exit-code error", err)
	}
}
