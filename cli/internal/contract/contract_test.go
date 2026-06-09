package contract

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// strictDecode fails if the fixture contains any field the struct does not
// model — guarding the structs against drifting behind docs/cli-contract.md.
func strictDecode(t *testing.T, data []byte, v any) {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		t.Fatalf("fixture has fields the contract struct does not model: %v", err)
	}
}

func TestParseStatusFixture(t *testing.T) {
	data := fixture(t, "status.json")

	s, err := ParseStatus(data)
	if err != nil {
		t.Fatalf("ParseStatus: %v", err)
	}
	strictDecode(t, data, &Status{})

	// Escaping edge cases survive decoding.
	if want := "pic\"sure\\back\ttab"; s.Env.ComposeProjectName != want {
		t.Errorf("compose_project_name = %q, want %q", s.Env.ComposeProjectName, want)
	}
	if s.Repos[0].Current == nil || *s.Repos[0].Current != "feat/we\"ird\\branch" {
		t.Errorf("repos[0].current = %v", s.Repos[0].Current)
	}

	// Nullable fields.
	if s.Env.FileValid == nil || !*s.Env.FileValid {
		t.Error("env.file_valid should be true")
	}
	if s.Repos[2].Current != nil {
		t.Error("missing repo should have null current")
	}
	if s.Services[0].Health != nil {
		t.Error("wildfly health should be null")
	}
	if s.Services[1].ExitCode != nil {
		t.Error("hpds exit_code should be null")
	}
	if s.Services[2].ExitCode == nil || *s.Services[2].ExitCode != 137 {
		t.Error("picsure-db exit_code should be 137")
	}
	if s.Database.Service != nil {
		t.Error("remote database should have null service")
	}
	if len(s.ReleaseControl.Refs) != 10 {
		t.Errorf("want 10 refs, got %d", len(s.ReleaseControl.Refs))
	}
	if s.Migrations.Ready == nil || *s.Migrations.Ready {
		t.Error("migrations.ready should be false")
	}
}

func TestParsePreflightFixture(t *testing.T) {
	data := fixture(t, "preflight.json")

	p, err := ParsePreflight(data)
	if err != nil {
		t.Fatalf("ParsePreflight: %v", err)
	}
	strictDecode(t, data, &Preflight{})

	if p.Passed {
		t.Error("fixture should not pass (has fails)")
	}
	if !p.NetworkChecked {
		t.Error("network_checked should be true")
	}
	if len(p.Checks) != 9 {
		t.Errorf("want 9 checks, got %d", len(p.Checks))
	}

	// Duplicate names are allowed — checks are a list, not a map.
	var generated int
	for _, c := range p.Checks {
		if c.Name == "compose.generated" {
			generated++
		}
	}
	if generated != 2 {
		t.Errorf("want 2 compose.generated checks, got %d", generated)
	}

	// Escaping edge cases (quotes, backslashes, tab, newline).
	want := "weird \"quoted\" path\\with\\backslashes\tand a tab\nand a newline"
	if p.Checks[7].Message != want {
		t.Errorf("message = %q, want %q", p.Checks[7].Message, want)
	}
}

func TestParseStatusRejectsWrongSchemaVersion(t *testing.T) {
	_, err := ParseStatus([]byte(`{"schema_version": 2, "command": "status"}`))
	if err == nil {
		t.Fatal("expected error for schema_version 2")
	}
}

func TestParseStatusRejectsWrongCommand(t *testing.T) {
	_, err := ParseStatus([]byte(`{"schema_version": 1, "command": "preflight"}`))
	if err == nil {
		t.Fatal("expected error for wrong command")
	}
}

func TestParseToleratesUnknownFields(t *testing.T) {
	// Additive contract changes must not break older binaries.
	_, err := ParsePreflight([]byte(`{"schema_version": 1, "command": "preflight", "passed": true, "checks": [], "future_field": 42}`))
	if err != nil {
		t.Fatalf("unknown top-level fields must be ignored: %v", err)
	}
}
