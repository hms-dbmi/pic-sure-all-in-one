package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

var (
	menuItemStyle = lipgloss.NewStyle()
	// menuSelectedStyle: Reverse for high-contrast selection, Bold for
	// legibility on low-contrast terminal themes where Reverse alone is subtle.
	menuSelectedStyle = lipgloss.NewStyle().Reverse(true).Bold(true)
)

type menuItem struct {
	ID    string
	Label string
}

type menu struct {
	items    []menuItem
	selected int
}

func newMenu(items ...menuItem) *menu { return &menu{items: items} }

func (m *menu) move(delta int) {
	if len(m.items) == 0 {
		return
	}
	m.selected = (m.selected + delta + len(m.items)) % len(m.items)
}

func (m *menu) selectedItem() menuItem {
	if len(m.items) == 0 {
		return menuItem{}
	}
	return m.items[m.selected]
}

// view renders one centered line per item at the given inner width; the
// selected item is reverse-video with a ▸ marker.
func (m *menu) view(width int) string {
	lines := make([]string, len(m.items))
	for i, item := range m.items {
		label := "  " + item.Label + "  "
		if i == m.selected {
			label = "▸ " + item.Label + " ◂"
		}
		centered := lipgloss.NewStyle().Width(width).Align(lipgloss.Center).Render(label)
		if i == m.selected {
			lines[i] = menuSelectedStyle.Render(centered)
		} else {
			lines[i] = menuItemStyle.Render(centered)
		}
	}
	return strings.Join(lines, "\n")
}
