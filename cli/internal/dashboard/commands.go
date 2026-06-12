package dashboard

import (
	"bytes"
	"context"
	"os/exec"
	"path/filepath"
	"syscall"
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

// pollCmd builds a context-bound `bash <script> <args>` poll. The script's
// own context kill only reaches bash, but compose/status.sh run `docker
// compose` as a non-exec'd child, so the grandchild inherits the stdout pipe.
// On a context timeout CommandContext would kill bash alone; the orphaned
// docker process keeps the write end open and Wait blocks on the I/O-copy
// goroutine until EOF — forever if the daemon is hung (the exact case the
// timeout guards against), silently wedging the poll. So, as in logs.go, run
// the poll in its own process group and kill the whole group on cancel;
// WaitDelay is a backstop in case a process escapes the group.
func pollCmd(ctx context.Context, root, script string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "bash", append([]string{filepath.Join(root, script)}, args...)...)
	cmd.Dir = root
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	return cmd
}

// pollServices reads service state through the compose wrapper — never
// docker compose directly, so file/project selection stays in bash. Parsed
// in Go (never run_jq here: its dockerized fallback would spawn a container
// every tick).
func pollServices(root string) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		cmd := pollCmd(ctx, root, scripts.Compose, "ps", "--format", "json")
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
		cmd := pollCmd(ctx, root, scripts.Status, "--json")
		var out bytes.Buffer
		cmd.Stdout = &out
		if err := cmd.Run(); err != nil {
			return statusMsg{err: err}
		}
		status, err := contract.ParseStatus(out.Bytes())
		return statusMsg{status: status, err: err}
	}
}
