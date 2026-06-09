// Package dashboard is the pic-sure dashboard screen: live service/status
// panes, a log follower, and keybound script actions running in an embedded
// PTY. All reads go through scripts/compose.sh and status.sh --json; all
// actions are the real scripts (docs/cli-contract.md). It is embedded as a
// sibling screen of the unified TUI (internal/tui).
package dashboard

import (
	tea "github.com/charmbracelet/bubbletea"
)

// BackMsg asks the embedding program to leave the dashboard (esc in normal
// mode).
type BackMsg struct{}

// New builds the dashboard model for embedding by the unified TUI.
func New(root string) tea.Model {
	return newModel(root)
}
