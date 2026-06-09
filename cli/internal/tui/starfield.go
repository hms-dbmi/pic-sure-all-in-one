package tui

import (
	"math/rand/v2"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// Braille sub-pixel starfield (technique from Basecamp ONCE's installer, MIT;
// reimplemented for bubbletea v1). Each terminal cell is a U+2800-block
// braille character giving a 2×4 sub-pixel grid; stars fly toward the viewer
// via perspective projection (x/z, y/z) and brighten as they approach.
const (
	starCount = 100
	starSpeed = 0.03
	starMinZ  = 0.1
	starMaxZ  = 3.0
	starTick  = 33 * time.Millisecond
)

// Braille dot bits by sub-row (top→bottom) for the left and right dot column.
var (
	leftDots  = [4]rune{0x01, 0x02, 0x04, 0x40}
	rightDots = [4]rune{0x08, 0x10, 0x20, 0x80}
)

var (
	starBrightStyle = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "0", Dark: "15"})
	starDimStyle    = lipgloss.NewStyle().Faint(true)
)

type starTickMsg struct{ seq int }

type star struct{ x, y, z float64 }

type starCell struct {
	ch     rune
	bright bool
}

type starfield struct {
	width, height int
	stars         []star
	grid          [][]starCell
	seq           int // animation generation; stale ticks are dropped
	// glyphs, when non-empty, render near (bright) stars as cell-granular
	// sparkle glyphs instead of braille dots; far stars stay sub-pixel.
	glyphs []rune
}

func newStarfield(glyphs []rune) *starfield { return &starfield{glyphs: glyphs} }

// startTicks begins a fresh animation chain, invalidating any in-flight one.
func (s *starfield) startTicks() tea.Cmd {
	s.seq++
	return s.tick()
}

// stopTicks invalidates the running chain (the next in-flight tick is dropped).
func (s *starfield) stopTicks() { s.seq++ }

func (s *starfield) tick() tea.Cmd {
	seq := s.seq
	return tea.Tick(starTick, func(time.Time) tea.Msg { return starTickMsg{seq: seq} })
}

// update advances the field on its own ticks; returns the reschedule command
// or nil for stale ticks.
func (s *starfield) update(msg starTickMsg) tea.Cmd {
	if msg.seq != s.seq {
		return nil
	}
	s.step()
	return s.tick()
}

func (s *starfield) resize(width, height int) {
	s.width, s.height = width, height
	s.stars = make([]star, starCount)
	for i := range s.stars {
		s.stars[i] = s.randomStar()
	}
	s.grid = make([][]starCell, height)
	for row := range s.grid {
		s.grid[row] = make([]starCell, width)
	}
}

func (s *starfield) step() {
	subW, subH := s.width*2, s.height*4
	centerX, centerY := float64(subW)/2, float64(subH)/2
	for i := range s.stars {
		st := &s.stars[i]
		st.z -= starSpeed
		if st.z <= starMinZ {
			s.stars[i] = s.randomStar()
			continue
		}
		sx := centerX + st.x/st.z
		sy := centerY + st.y/st.z
		if sx < 0 || sx >= float64(subW) || sy < 0 || sy >= float64(subH) {
			s.stars[i] = s.randomStar()
		}
	}
}

// computeGrid projects all stars onto the cell grid; call before renderRow.
func (s *starfield) computeGrid() {
	if s.width <= 0 || s.height <= 0 {
		return
	}
	for row := range s.grid {
		for col := range s.grid[row] {
			s.grid[row][col] = starCell{}
		}
	}
	subW, subH := s.width*2, s.height*4
	centerX, centerY := float64(subW)/2, float64(subH)/2
	for i := range s.stars {
		st := &s.stars[i]
		if st.z <= 0 {
			continue
		}
		sxi, syi := int(centerX+st.x/st.z), int(centerY+st.y/st.z)
		if sxi < 0 || sxi >= subW || syi < 0 || syi >= subH {
			continue
		}
		cell := &s.grid[syi/4][sxi/2]
		if st.z < starMaxZ/2 && len(s.glyphs) > 0 {
			// Near star with sparkle glyphs configured: the glyph owns the
			// whole cell (a glyph rune must never be OR'd with dot bits).
			cell.ch = s.glyphs[i%len(s.glyphs)]
			cell.bright = true
			continue
		}
		if isGlyphRune(cell.ch) {
			continue // a sparkle already owns this cell
		}
		if cell.ch == 0 {
			cell.ch = 0x2800
		}
		if sxi%2 == 0 {
			cell.ch |= leftDots[syi%4]
		} else {
			cell.ch |= rightDots[syi%4]
		}
		if st.z < starMaxZ/2 {
			cell.bright = true
		}
	}
}

// isGlyphRune reports a non-braille (sparkle glyph) cell rune.
func isGlyphRune(r rune) bool { return r != 0 && (r < 0x2800 || r > 0x28FF) }

// cellView renders one cell, or "" when empty — the layering hook for the
// landing background (stars in front, watermark behind).
func (s *starfield) cellView(row, col int) string {
	if row < 0 || row >= s.height || col < 0 || col >= s.width {
		return ""
	}
	cell := s.grid[row][col]
	if cell.ch == 0 {
		return ""
	}
	if cell.bright {
		return starBrightStyle.Render(string(cell.ch))
	}
	return starDimStyle.Render(string(cell.ch))
}

// renderRow renders starfield cells for columns [fromCol, toCol) of a row.
func (s *starfield) renderRow(row, fromCol, toCol int) string {
	if row < 0 || row >= s.height {
		return strings.Repeat(" ", max(toCol-fromCol, 0))
	}
	var sb strings.Builder
	for col := fromCol; col < toCol; col++ {
		if cv := s.cellView(row, col); cv != "" {
			sb.WriteString(cv)
		} else {
			sb.WriteByte(' ')
		}
	}
	return sb.String()
}

func (s *starfield) randomStar() star {
	spread := float64(max(s.width, s.height))
	return star{
		x: (rand.Float64() - 0.5) * spread,
		y: (rand.Float64() - 0.5) * spread,
		z: starMinZ + rand.Float64()*(starMaxZ-starMinZ),
	}
}
