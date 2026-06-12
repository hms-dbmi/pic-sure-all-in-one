package project

import (
	"path/filepath"
	"strings"
	"testing"
)

// fixtureRoot is cli/testdata/fixtures/root, which contains the two marker
// files plus a nested sub/dir to walk up from.
func fixtureRoot(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs(filepath.Join("..", "..", "testdata", "fixtures", "root"))
	if err != nil {
		t.Fatal(err)
	}
	return abs
}

func TestFindRootFromNestedSubdir(t *testing.T) {
	root := fixtureRoot(t)
	got, err := FindRoot(filepath.Join(root, "sub", "dir"), "")
	if err != nil {
		t.Fatalf("FindRoot: %v", err)
	}
	if got != root {
		t.Errorf("got %s, want %s", got, root)
	}
}

func TestFindRootAtRootItself(t *testing.T) {
	root := fixtureRoot(t)
	got, err := FindRoot(root, "")
	if err != nil {
		t.Fatalf("FindRoot: %v", err)
	}
	if got != root {
		t.Errorf("got %s, want %s", got, root)
	}
}

func TestFindRootOverride(t *testing.T) {
	root := fixtureRoot(t)
	got, err := FindRoot(t.TempDir(), root)
	if err != nil {
		t.Fatalf("FindRoot with override: %v", err)
	}
	if got != root {
		t.Errorf("got %s, want %s", got, root)
	}
}

func TestFindRootOverrideInvalid(t *testing.T) {
	_, err := FindRoot(".", t.TempDir())
	if err == nil {
		t.Fatal("expected error for non-root override")
	}
	if !strings.Contains(err.Error(), ".env.example") {
		t.Errorf("error should name the missing markers, got: %v", err)
	}
}

func TestFindRootNotFound(t *testing.T) {
	_, err := FindRoot(t.TempDir(), "")
	if err == nil {
		t.Fatal("expected error when no root exists upward")
	}
	if !strings.Contains(err.Error(), "--root") {
		t.Errorf("error should mention --root, got: %v", err)
	}
}

// TestMarkersListContainsAllMarkers ensures MarkersList() names every file
// that isRoot actually checks — so help text derived from it cannot drift.
func TestMarkersListContainsAllMarkers(t *testing.T) {
	list := MarkersList()
	for _, m := range markers {
		if !strings.Contains(list, m) {
			t.Errorf("MarkersList() = %q: missing marker %q", list, m)
		}
	}
}
