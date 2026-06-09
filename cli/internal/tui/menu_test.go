package tui

import (
	"strings"
	"testing"
)

func testMenu() *menu {
	return newMenu(
		menuItem{ID: "a", Label: "Alpha"},
		menuItem{ID: "b", Label: "Beta"},
		menuItem{ID: "c", Label: "Gamma"},
	)
}

func TestMenuMovesAndWraps(t *testing.T) {
	m := testMenu()
	m.move(-1)
	if m.selectedItem().ID != "c" {
		t.Errorf("up from first = %q, want wrap to c", m.selectedItem().ID)
	}
	m.move(1)
	if m.selectedItem().ID != "a" {
		t.Errorf("down from last = %q, want wrap to a", m.selectedItem().ID)
	}
	m.move(1)
	if m.selectedItem().ID != "b" {
		t.Errorf("down = %q, want b", m.selectedItem().ID)
	}
}

func TestMenuViewMarksSelection(t *testing.T) {
	m := testMenu()
	m.move(1) // select Beta
	view := m.view(20)
	if view == "" {
		t.Fatal("empty menu view")
	}
	// The selected row renders with the ▸ marker; others with spaces.
	lines := splitLines(view)
	if len(lines) != 3 {
		t.Fatalf("menu rendered %d lines, want 3", len(lines))
	}
	if !strings.Contains(lines[1], "▸") || !strings.Contains(lines[1], "◂") {
		t.Errorf("selected line %q missing ▸/◂ markers", lines[1])
	}
	for _, i := range []int{0, 2} {
		if strings.Contains(lines[i], "▸") || strings.Contains(lines[i], "◂") {
			t.Errorf("unselected line %d %q should not contain markers", i, lines[i])
		}
	}
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i, r := range s {
		if r == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}
