package tui

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/styles"
)

const (
	logoShineInterval = 10 * time.Second
	logoShineDelay    = 2 * time.Second
	logoShineTickRate = 50 * time.Millisecond
	logoShineStep     = 2
	logoShineBand     = 4
)

var (
	logoBaseStyle = lipgloss.NewStyle().Faint(true)
	// Shine sweeps in the shared PIC-SURE brand hue (styles.Brand): exact
	// #224D96 on light terminals; on dark ones the same hue lifted to oklch 70%
	// lightness (#6F9EEF) so the sweep stays visible over faint gray glyphs.
	logoShineStyle = lipgloss.NewStyle().Foreground(styles.Brand)
)

var logoArt = []string{
	`██████╗  ██╗  ██████╗         ███████╗ ██╗   ██╗ ██████╗  ███████╗`,
	`██╔══██╗ ██║ ██╔════╝         ██╔════╝ ██║   ██║ ██╔══██╗ ██╔════╝`,
	`██████╔╝ ██║ ██║      █████╗  ███████╗ ██║   ██║ ██████╔╝ █████╗  `,
	`██╔═══╝  ██║ ██║      ╚════╝  ╚════██║ ██║   ██║ ██╔══██╗ ██╔══╝  `,
	`██║      ██║ ╚██████╗         ███████║ ╚██████╔╝ ██║  ██║ ███████╗`,
	`╚═╝      ╚═╝  ╚═════╝         ╚══════╝  ╚═════╝  ╚═╝  ╚═╝ ╚══════╝`,
}

// logoWidth is the rune width of the block art (all rows are uniform).
func logoWidth() int { return len([]rune(logoArt[0])) }

type logoShineStartMsg struct{}

type logoShineStepMsg struct{}

type logo struct {
	lines    [][]rune
	shinePos int // -1 when idle
	maxDiag  int
}

func newLogo() *logo {
	lines := make([][]rune, len(logoArt))
	for i, line := range logoArt {
		lines[i] = []rune(line)
	}
	return &logo{lines: lines, shinePos: -1, maxDiag: logoWidth() + len(logoArt)}
}

// startShine schedules the first sweep, or nothing when animations are off
// (the logo still renders, statically — spec: kill switch never changes
// layout or colors).
func (l *logo) startShine(animations bool) tea.Cmd {
	if !animations {
		return nil
	}
	return tea.Tick(logoShineDelay, func(time.Time) tea.Msg { return logoShineStartMsg{} })
}

func (l *logo) update(msg tea.Msg) tea.Cmd {
	switch msg.(type) {
	case logoShineStartMsg:
		if l.shinePos >= 0 {
			return nil // already sweeping (duplicate chain guard)
		}
		l.shinePos = 0
		return l.shineTick()
	case logoShineStepMsg:
		if l.shinePos < 0 {
			return nil // stale step after a suspend
		}
		l.shinePos += logoShineStep
		if l.shinePos > l.maxDiag+logoShineBand {
			l.shinePos = -1
			return tea.Tick(logoShineInterval, func(time.Time) tea.Msg { return logoShineStartMsg{} })
		}
		return l.shineTick()
	}
	return nil
}

// stopShine halts the sweep; in-flight step messages become no-ops.
func (l *logo) stopShine() { l.shinePos = -1 }

func (l *logo) view() string {
	var sb strings.Builder
	for i, line := range l.lines {
		if i > 0 {
			sb.WriteByte('\n')
		}
		sb.WriteString(l.renderLine(line, i))
	}
	return sb.String()
}

func (l *logo) renderLine(line []rune, row int) string {
	if l.shinePos < 0 {
		return logoBaseStyle.Render(string(line))
	}
	shineStart := l.shinePos - row
	shineEnd := shineStart + logoShineBand
	if shineStart >= len(line) || shineEnd <= 0 {
		return logoBaseStyle.Render(string(line))
	}
	shineStart = max(shineStart, 0)
	shineEnd = min(shineEnd, len(line))
	var sb strings.Builder
	if shineStart > 0 {
		sb.WriteString(logoBaseStyle.Render(string(line[:shineStart])))
	}
	sb.WriteString(logoShineStyle.Render(string(line[shineStart:shineEnd])))
	if shineEnd < len(line) {
		sb.WriteString(logoBaseStyle.Render(string(line[shineEnd:])))
	}
	return sb.String()
}

func (l *logo) shineTick() tea.Cmd {
	return tea.Tick(logoShineTickRate, func(time.Time) tea.Msg { return logoShineStepMsg{} })
}
