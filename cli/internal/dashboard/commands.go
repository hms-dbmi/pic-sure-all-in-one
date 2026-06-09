package dashboard

import (
	"bytes"
	"context"
	"os/exec"
	"path/filepath"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/contract"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"
)

// Poll intervals. Services are cheap (compose ps through the wrapper);
// status.sh --json embeds the migration check, which is local-only by
// contract (docs/cli-contract.md), so 15s is safe.
const (
	servicesInterval = 2 * time.Second
	statusInterval   = 15 * time.Second
)

type (
	servicesTickMsg struct{}
	statusTickMsg   struct{}

	servicesMsg struct {
		services []contract.ComposeService
		err      error
	}
	statusMsg struct {
		status *contract.Status
		err    error
	}

	logLinesMsg struct {
		sessionID int
		lines     []string
	}
	logClosedMsg struct {
		sessionID int
	}
)

func servicesTick() tea.Cmd {
	return tea.Tick(servicesInterval, func(time.Time) tea.Msg { return servicesTickMsg{} })
}

func statusTick() tea.Cmd {
	return tea.Tick(statusInterval, func(time.Time) tea.Msg { return statusTickMsg{} })
}

// pollServices reads service state through the compose wrapper — never
// docker compose directly, so file/project selection stays in bash. Parsed
// in Go (never run_jq here: its dockerized fallback would spawn a container
// every tick).
func pollServices(root string) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "bash", filepath.Join(root, scripts.Compose), "ps", "--format", "json")
		cmd.Dir = root
		var out bytes.Buffer
		cmd.Stdout = &out
		if err := cmd.Run(); err != nil {
			return servicesMsg{err: err}
		}
		services, err := contract.ParseComposePS(out.Bytes())
		return servicesMsg{services: services, err: err}
	}
}

func pollStatus(root string) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "bash", filepath.Join(root, scripts.Status), "--json")
		cmd.Dir = root
		var out bytes.Buffer
		cmd.Stdout = &out
		if err := cmd.Run(); err != nil {
			return statusMsg{err: err}
		}
		status, err := contract.ParseStatus(out.Bytes())
		return statusMsg{status: status, err: err}
	}
}
