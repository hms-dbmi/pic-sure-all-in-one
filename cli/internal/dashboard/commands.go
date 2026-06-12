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

// Log-follower restart backoff: a dead follower is restarted after a delay
// that doubles on each consecutive failed restart, capped at logRetryMax, so a
// service whose `compose logs -f` keeps failing is retried ever less often
// instead of every servicesInterval. The delay resets once a session delivers
// real lines.
const (
	logRetryBase = 2 * time.Second
	logRetryMax  = 30 * time.Second
)

// nextLogRetryDelay computes the next backoff from the previous one: it starts
// at logRetryBase and doubles up to logRetryMax. Pure so tests can assert the
// schedule grows without sleeping.
func nextLogRetryDelay(prev time.Duration) time.Duration {
	if prev < logRetryBase {
		return logRetryBase
	}
	if d := prev * 2; d < logRetryMax {
		return d
	}
	return logRetryMax
}

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
	// logRetryMsg fires after the backoff delay to restart a dead follower for
	// seq's service (stamped with the logSeq the closure observed so a restart
	// scheduled for an old service is discarded once the user has switched).
	logRetryMsg struct {
		seq int
	}
)

// logRetry schedules a follower restart after delay, stamped with seq.
func logRetry(seq int, delay time.Duration) tea.Cmd {
	return tea.Tick(delay, func(time.Time) tea.Msg { return logRetryMsg{seq: seq} })
}

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
// timeout guards against), silently wedging the poll. So, borrowing logs.go's
// group-kill idea, run the poll in its own process group and bring the whole
// group down on cancel; WaitDelay is a backstop in case a process escapes
// the group.
func pollCmd(ctx context.Context, root, script string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "bash", append([]string{filepath.Join(root, script)}, args...)...)
	cmd.Dir = root
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// SIGKILL, not logs.go's SIGTERM: a hung-daemon grandchild may ignore TERM, and polls have nothing to drain.
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
