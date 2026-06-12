package dashboard

import (
	"bufio"
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"
)

// logSession follows one service's logs through the compose wrapper. Lines
// arrive over a channel; waitLogLine bridges them into Bubble Tea messages
// one at a time. Sessions are identified so output from a cancelled session
// (after a selection change) can be discarded.
type logSession struct {
	id     int
	cancel context.CancelFunc
	lines  chan string
	// failed is true for a stub session that could not start the follower (it
	// only ever delivers a single error line then closes). The retry loop uses
	// it to tell a real, briefly-lived session (reset the backoff) apart from a
	// hard startup failure (keep backing off).
	failed bool
}

func startLogSession(root, service string, id int) *logSession {
	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, "bash", filepath.Join(root, scripts.Compose), "logs", "-f", "--tail", "200", service)
	cmd.Dir = root
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		// Kill the whole group: compose spawns children.
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
	// Backstop (same escape-the-group wedge class fixed in the pollers): if a
	// SIGTERM-ignoring descendant escapes the group kill, it keeps the stdout
	// pipe's write end open and cmd.Wait would block on the I/O-copy goroutine
	// forever, leaking the reaper goroutine. WaitDelay forces Wait to return
	// shortly after cancellation regardless.
	cmd.WaitDelay = 2 * time.Second

	lines := make(chan string, 256)

	// On startup failure, surface the error as a log line instead of
	// leaving the pane silently empty, then close (the retry loop backs off).
	failed := func(stage string, err error) *logSession {
		cancel()
		lines <- fmt.Sprintf("[log follower] %s failed: %v", stage, err)
		close(lines)
		return &logSession{id: id, cancel: func() {}, lines: lines, failed: true}
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return failed("pipe", err)
	}
	cmd.Stderr = cmd.Stdout

	if err := cmd.Start(); err != nil {
		return failed("start", err)
	}

	go func() {
		defer close(lines)
		defer func() { _ = cmd.Wait() }()
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			select {
			case lines <- scanner.Text():
			case <-ctx.Done():
				return
			}
		}
	}()

	return &logSession{id: id, cancel: cancel, lines: lines}
}

// waitLines blocks for the next line, then drains everything else already
// buffered so a log flood costs one viewport rebuild per batch instead of
// one per line. If the channel closes mid-drain the batch is still
// delivered; the next call reports the closure.
func (s *logSession) waitLines() tea.Cmd {
	return func() tea.Msg {
		line, ok := <-s.lines
		if !ok {
			return logClosedMsg{sessionID: s.id}
		}
		batch := []string{line}
		for len(batch) < maxLogLines {
			select {
			case l, ok := <-s.lines:
				if !ok {
					return logLinesMsg{sessionID: s.id, lines: batch}
				}
				batch = append(batch, l)
			default:
				return logLinesMsg{sessionID: s.id, lines: batch}
			}
		}
		return logLinesMsg{sessionID: s.id, lines: batch}
	}
}

func (s *logSession) stop() {
	s.cancel()
}
