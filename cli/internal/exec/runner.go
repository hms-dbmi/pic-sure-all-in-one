// Package exec runs the repository's bash scripts as foreground child
// processes: live unbuffered stdio and the script's exit code propagated.
// Process-group placement depends on stdin: on a terminal the script stays
// in the CLI's foreground group (a separate group would be stopped with
// SIGTTIN on its first TTY read); otherwise it gets its own group with
// SIGINT/SIGTERM forwarded to the whole group.
package exec

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	osexec "os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/mattn/go-isatty"
)

// Run executes the script (a path relative to root, e.g. "init.sh" or
// "scripts/compose.sh") with args, from the root directory. It blocks until
// the script exits and returns the script's exit code; signals received by
// the CLI are forwarded to the script (to its whole process group when stdin
// is not a terminal).
func Run(root, script string, args []string) (int, error) {
	return run(root, script, args, os.Stdin)
}

// RunWithInput is Run with the script's stdin fed from input instead of the
// terminal — used to pass secrets without exposing them in argv.
func RunWithInput(root, script string, args []string, input string) (int, error) {
	return run(root, script, args, strings.NewReader(input))
}

func run(root, script string, args []string, stdin io.Reader) (int, error) {
	argv := append([]string{filepath.Join(root, script)}, args...)
	cmd := osexec.Command("bash", argv...)
	cmd.Dir = root
	// Inherit stdout/stderr directly: no Go-side buffering, scripts keep
	// their colors and interactivity.
	cmd.Stdin = stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	// On a terminal the child must share the CLI's foreground process group:
	// in its own group, the kernel stops it with SIGTTIN the moment it reads
	// from the TTY (reset.sh's confirmation prompt), and a forwarded SIGINT
	// then sits pending on the stopped process — the CLI hangs until
	// SIGKILLed. Sharing the group also hands terminal Ctrl-C to the script
	// natively. Off-terminal, job control can't interfere, so the child gets
	// its own group and signal forwarding reaches the script and every child
	// it spawns (docker, git, maven, ...).
	onTTY := stdinIsTerminal(stdin)
	if !onTTY {
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	}

	// Install the handler before Start so a Ctrl-C in the window between
	// Start and Notify can't kill the CLI (default disposition) while the
	// child, in its own process group, survives orphaned. Signals arriving
	// before the forwarding goroutine runs sit buffered in sigCh.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	if err := cmd.Start(); err != nil {
		signal.Stop(sigCh)
		return 1, err
	}

	done := make(chan struct{})
	go func() {
		for {
			select {
			case sig := <-sigCh:
				s, ok := sig.(syscall.Signal)
				if !ok {
					continue
				}
				if !onTTY {
					// Negative pid targets the whole process group.
					_ = syscall.Kill(-cmd.Process.Pid, s)
				} else if s == syscall.SIGTERM {
					// The shared foreground group already gets the terminal's
					// Ctrl-C, so forwarding SIGINT would deliver it twice; a
					// SIGTERM aimed at the CLI alone must still reach the
					// script. Either way Notify keeps the CLI alive until
					// Wait reports the child's fate.
					_ = syscall.Kill(cmd.Process.Pid, s)
				}
			case <-done:
				return
			}
		}
	}()

	err := cmd.Wait()
	close(done)
	signal.Stop(sigCh)

	return CodeFromWait(err)
}

// stdinIsTerminal reports whether the child's stdin is a real terminal. The
// char-device test behind tty.IsInteractive is too loose for process-group
// placement: /dev/null is a character device too (the stdin go test and many
// schedulers provide), but job control only ever applies to a controlling
// terminal, and only the terminal case may give up group-targeted signal
// forwarding.
func stdinIsTerminal(stdin io.Reader) bool {
	f, ok := stdin.(*os.File)
	return ok && isatty.IsTerminal(f.Fd())
}

// RunQuiet is Run with output captured instead of inherited — for hosts that
// own the terminal (the TUI's wizard screen) and must not let script output
// corrupt the screen. On a nonzero exit the script's stderr is folded into
// the returned error, because the TUI host has no scrollback to consult.
// No signal forwarding: the quiet runners exist for fast, non-interactive
// helper scripts (env-set.sh), not long-running operations.
func RunQuiet(root, script string, args []string) (int, error) {
	return runQuiet(root, script, args, "")
}

// RunQuietWithInput is RunQuiet with stdin fed from input (secrets never
// appear in argv).
func RunQuietWithInput(root, script string, args []string, input string) (int, error) {
	return runQuiet(root, script, args, input)
}

// RunOutput is RunQuiet with stdout captured and returned to the caller —
// for frontends needing a script's machine-readable output (status --json)
// while owning the terminal. Stderr is folded into the error on a nonzero
// exit, as in RunQuiet.
func RunOutput(root, script string, args []string) (int, string, error) {
	argv := append([]string{filepath.Join(root, script)}, args...)
	cmd := osexec.Command("bash", argv...)
	cmd.Dir = root
	cmd.Stdin = strings.NewReader("")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	code, err := CodeFromWait(cmd.Run())
	if err == nil && code != 0 && stderr.Len() > 0 {
		err = fmt.Errorf("exit %d: %s", code, strings.TrimSpace(stderr.String()))
	}
	return code, stdout.String(), err
}

func runQuiet(root, script string, args []string, input string) (int, error) {
	argv := append([]string{filepath.Join(root, script)}, args...)
	cmd := osexec.Command("bash", argv...)
	cmd.Dir = root
	cmd.Stdin = strings.NewReader(input)
	cmd.Stdout = io.Discard
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	code, err := CodeFromWait(cmd.Run())
	if err == nil && code != 0 && stderr.Len() > 0 {
		err = fmt.Errorf("exit %d: %s", code, strings.TrimSpace(stderr.String()))
	}
	return code, err
}

// CodeFromWait converts a cmd.Wait error into an exit code, encoding signal
// deaths as 128+N (conventional shell encoding). Used by both the plain
// runner and the dashboard's PTY runner so the two never disagree.
func CodeFromWait(err error) (int, error) {
	if err == nil {
		return 0, nil
	}
	var exitErr *osexec.ExitError
	if errors.As(err, &exitErr) {
		if ws, ok := exitErr.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal()), nil
		}
		return exitErr.ExitCode(), nil
	}
	return 1, err
}
