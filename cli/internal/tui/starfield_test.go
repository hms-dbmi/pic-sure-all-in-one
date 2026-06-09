package tui

import (
	"testing"

	"github.com/charmbracelet/lipgloss"
)

func TestStarfieldGridCellsAreBrailleOrEmpty(t *testing.T) {
	s := newStarfield(nil)
	s.resize(40, 12)
	for i := 0; i < 50; i++ { // run well past one star lifetime
		s.step()
	}
	s.computeGrid()
	for row := 0; row < 12; row++ {
		for col := 0; col < 40; col++ {
			ch := s.grid[row][col].ch
			if ch != 0 && (ch < 0x2800 || ch > 0x28FF) {
				t.Fatalf("grid[%d][%d] = %U, want 0 or braille block", row, col, ch)
			}
		}
	}
}

func TestStarfieldRowWidthMatchesTerminal(t *testing.T) {
	s := newStarfield(nil)
	s.resize(40, 12)
	s.computeGrid()
	for row := 0; row < 12; row++ {
		if w := lipgloss.Width(s.renderRow(row, 0, 40)); w != 40 {
			t.Errorf("row %d width = %d, want 40", row, w)
		}
	}
	// Margins: render only columns [5, 15) → width 10.
	if w := lipgloss.Width(s.renderRow(0, 5, 15)); w != 10 {
		t.Errorf("partial row width = %d, want 10", w)
	}
}

func TestStarfieldStaleTickDropped(t *testing.T) {
	s := newStarfield(nil)
	s.resize(40, 12)
	cmd := s.startTicks() // seq becomes 1
	if cmd == nil {
		t.Fatal("startTicks returned nil")
	}
	s.startTicks() // seq becomes 2; the seq-1 chain is now stale
	if next := s.update(starTickMsg{seq: 1}); next != nil {
		t.Error("stale tick was rescheduled; want chain dropped")
	}
	if next := s.update(starTickMsg{seq: 2}); next == nil {
		t.Error("current tick was not rescheduled")
	}
}

func TestStarfieldBrightStarsRenderGlyphs(t *testing.T) {
	s := newStarfield([]rune{'✦'})
	s.resize(40, 12)
	// One near star dead center: z below starMaxZ/2 → bright → glyph cell.
	s.stars = []star{{x: 0, y: 0, z: 0.5}}
	s.computeGrid()
	found := false
	for row := range s.grid {
		for col := range s.grid[row] {
			if s.grid[row][col].ch == '✦' {
				found = true
				if !s.grid[row][col].bright {
					t.Error("glyph cell not marked bright")
				}
			}
		}
	}
	if !found {
		t.Fatal("near star did not render as the sparkle glyph")
	}
	// nil glyphs preserve pure-braille behavior (covered by the grid test).
}

func TestStarGlyphsParsing(t *testing.T) {
	env := func(v string) func(string) string {
		return func(string) string { return v }
	}
	if g := starGlyphs(env("")); len(g) != 1 || g[0] != defaultStarGlyph {
		t.Errorf("default = %q, want sparkle", string(g))
	}
	if g := starGlyphs(env("✦,✧")); len(g) != 2 || g[1] != '✧' {
		t.Errorf("multi = %q, want two glyphs", string(g))
	}
	// Multi-rune or wide entries are dropped; all-invalid falls back.
	if g := starGlyphs(env("ab,⭐⭐")); len(g) != 1 || g[0] != defaultStarGlyph {
		t.Errorf("invalid entries = %q, want fallback to default", string(g))
	}
}
