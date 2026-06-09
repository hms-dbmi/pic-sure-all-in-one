package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

func TestLogoRowsAreUniformWidth(t *testing.T) {
	l := newLogo()
	lines := strings.Split(l.view(), "\n")
	if len(lines) != 6 {
		t.Fatalf("logo has %d lines, want 6", len(lines))
	}
	w := lipgloss.Width(lines[0])
	if w < 40 {
		t.Fatalf("logo width %d implausibly small", w)
	}
	for i, line := range lines {
		if lw := lipgloss.Width(line); lw != w {
			t.Errorf("line %d width = %d, want %d", i, lw, w)
		}
	}
	if logoWidth() != w {
		t.Errorf("logoWidth() = %d, want rendered width %d", logoWidth(), w)
	}
}

func TestLogoShineRendersWithoutChangingWidth(t *testing.T) {
	l := newLogo()
	l.shinePos = 10 // mid-sweep
	for i, line := range strings.Split(l.view(), "\n") {
		if w := lipgloss.Width(line); w != logoWidth() {
			t.Errorf("shining line %d width = %d, want %d", i, w, logoWidth())
		}
	}
}

func TestLogoShineDisabledWithoutAnimations(t *testing.T) {
	l := newLogo()
	if cmd := l.startShine(false); cmd != nil {
		t.Error("startShine(false) scheduled a command; want nil (static logo)")
	}
	if cmd := l.startShine(true); cmd == nil {
		t.Error("startShine(true) returned nil; want shine schedule")
	}
}
