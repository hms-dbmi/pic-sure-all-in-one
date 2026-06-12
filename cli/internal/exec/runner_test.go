package exec

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/creack/pty"
)

func writeScript(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/usr/bin/env bash\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestRunPropagatesExitCode(t *testing.T) {
	dir := t.TempDir()
	writeScript(t, dir, "x.sh", "exit 7")
	code, err := Run(dir, "x.sh", nil)
	if err != nil {
		t.Fatal(err)
	}
	if code != 7 {
		t.Errorf("exit code = %d, want 7", code)
	}
}

func TestRunPassesArgsAndRunsFromRoot(t *testing.T) {
	dir := t.TempDir()
	// Proves args arrive verbatim and cwd is the root.
	writeScript(t, dir, "x.sh", `printf '%s|' "$@" > out.txt; pwd >> out.txt`)
	code, err := Run(dir, "x.sh", []string{"--branch=release/2.4", "a b"})
	if err != nil || code != 0 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "out.txt"))
	if err != nil {
		t.Fatal(err)
	}
	got := string(data)
	want := "--branch=release/2.4|a b|"
	if got[:len(want)] != want {
		t.Errorf("args = %q, want prefix %q", got, want)
	}
	// macOS tempdirs resolve through /private; compare resolved paths.
	wantDir, _ := filepath.EvalSymlinks(dir)
	gotDir, _ := filepath.EvalSymlinks(string(data[len(want) : len(data)-1]))
	if gotDir != wantDir {
		t.Errorf("cwd = %q, want %q", gotDir, wantDir)
	}
}

// TestRunPromptingScriptOnTTY pins the job-control contract for interactive
// runs. With a terminal as stdin the child must NOT get its own process
// group: a child in a non-foreground group of its controlling terminal is
// stopped by SIGTTIN the moment it reads from the TTY (empirical repro:
// `pic-sure reset` hung at reset.sh's confirmation prompt, child in ps state
// T, forwarded SIGINTs pending forever). The stop itself is not reproducible
// in-process — the PTY slave opened here is never the child's *controlling*
// terminal (that would require the runner to setsid+TIOCSCTTY, which is
// exactly what it must not do), and the kernel only sends SIGTTIN for reads
// on the controlling terminal. So this asserts the fix's contract instead:
// the child shares the test process's group, and the prompt round-trip
// completes with exit 0.
func TestRunPromptingScriptOnTTY(t *testing.T) {
	dir := t.TempDir()
	writeScript(t, dir, "prompt.sh",
		`ps -o pgid= -p $$ | tr -d ' ' > pgid.txt
read -r -p "ok? " x
[ "$x" = "y" ] || exit 9`)

	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer slave.Close()

	type result struct {
		code int
		err  error
	}
	done := make(chan result, 1)
	go func() {
		code, rerr := run(dir, "prompt.sh", nil, slave)
		done <- result{code, rerr}
	}()

	// The PTY line discipline buffers input written before the script's
	// read reaches the slave, so no need to wait for the prompt.
	if _, err := master.WriteString("y\n"); err != nil {
		t.Fatal(err)
	}

	select {
	case r := <-done:
		if r.err != nil || r.code != 0 {
			t.Fatalf("= (%d, %v), want (0, nil): prompt input never reached the script", r.code, r.err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("prompting script did not exit within 10s (stuck on TTY read)")
	}

	data, err := os.ReadFile(filepath.Join(dir, "pgid.txt"))
	if err != nil {
		t.Fatal(err)
	}
	got := strings.TrimSpace(string(data))
	want := strconv.Itoa(syscall.Getpgrp())
	if got != want {
		t.Errorf("child pgid = %s, want %s (the CLI's own group; a separate group invites SIGTTIN stops on TTY reads)", got, want)
	}
}

// TestRunOnTTYForwardsSIGTERMToChild: on the terminal path the child shares
// the CLI's group, so group-targeted forwarding is gone — but a SIGTERM
// aimed at the CLI pid alone must still reach the script, and the CLI must
// report the child's signal death as 128+N.
func TestRunOnTTYForwardsSIGTERMToChild(t *testing.T) {
	dir := t.TempDir()
	// exec: one process only — pid-targeted forwarding can't reach a
	// grandchild, and an orphaned sleep would hold go test's output pipe
	// open for its full duration.
	writeScript(t, dir, "sleepy.sh", "exec sleep 30")

	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer slave.Close()

	type result struct {
		code int
		err  error
	}
	done := make(chan result, 1)
	go func() {
		code, rerr := run(dir, "sleepy.sh", nil, slave)
		done <- result{code, rerr}
	}()

	time.Sleep(300 * time.Millisecond)
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}

	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("err = %v", r.err)
		}
		if r.code != 128+int(syscall.SIGTERM) {
			t.Errorf("exit code = %d, want %d (128+SIGTERM)", r.code, 128+int(syscall.SIGTERM))
		}
	case <-time.After(5 * time.Second):
		t.Fatal("script was not killed by forwarded SIGTERM within 5s")
	}
}

// TestRunOnTTYSurvivesSIGINT: on the terminal path the CLI shares the
// foreground group with the child, so a terminal Ctrl-C hits both. The CLI
// must outlive the child (to report its exit code) and must not forward the
// SIGINT a second time; here only the CLI pid is signaled mid-prompt and the
// child must still complete the round-trip.
func TestRunOnTTYSurvivesSIGINT(t *testing.T) {
	dir := t.TempDir()
	writeScript(t, dir, "prompt.sh", `read -r x; [ "$x" = "go" ] || exit 9`)

	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer slave.Close()

	type result struct {
		code int
		err  error
	}
	done := make(chan result, 1)
	go func() {
		code, rerr := run(dir, "prompt.sh", nil, slave)
		done <- result{code, rerr}
	}()

	// Signal while the child is blocked on the prompt, then answer it.
	time.Sleep(300 * time.Millisecond)
	if err := syscall.Kill(os.Getpid(), syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if _, err := master.WriteString("go\n"); err != nil {
		t.Fatal(err)
	}

	select {
	case r := <-done:
		if r.err != nil || r.code != 0 {
			t.Fatalf("= (%d, %v), want (0, nil): SIGINT to the CLI pid must not kill or interrupt the child", r.code, r.err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("prompting script did not exit within 10s after SIGINT to the CLI")
	}
}

func TestRunForwardsSignalsToProcessGroup(t *testing.T) {
	dir := t.TempDir()
	writeScript(t, dir, "sleepy.sh", "sleep 30")

	type result struct {
		code int
		err  error
	}
	done := make(chan result, 1)
	go func() {
		code, err := Run(dir, "sleepy.sh", nil)
		done <- result{code, err}
	}()

	// Give the script time to start, then signal ourselves; Run's handler
	// must forward it to the script's process group.
	time.Sleep(300 * time.Millisecond)
	if err := syscall.Kill(os.Getpid(), syscall.SIGINT); err != nil {
		t.Fatal(err)
	}

	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("err = %v", r.err)
		}
		if r.code != 128+int(syscall.SIGINT) {
			t.Errorf("exit code = %d, want %d (128+SIGINT)", r.code, 128+int(syscall.SIGINT))
		}
	case <-time.After(5 * time.Second):
		t.Fatal("script was not killed by forwarded SIGINT within 5s")
	}
}

func TestRunQuietCapturesStderrIntoError(t *testing.T) {
	root := t.TempDir()
	script := "noisy.sh"
	content := "#!/usr/bin/env bash\necho to-stdout\necho to-stderr >&2\nexit 7\n"
	if err := os.WriteFile(filepath.Join(root, script), []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}

	code, err := RunQuiet(root, script, nil)
	if code != 7 {
		t.Errorf("code = %d, want 7", code)
	}
	// The TUI host has no scrollback: a failing script's stderr must reach
	// the error message, and stdout must not leak to the terminal.
	if err == nil || !strings.Contains(err.Error(), "to-stderr") {
		t.Errorf("err = %v, want script stderr folded in", err)
	}

	// Success: no error, no noise.
	ok := "quiet.sh"
	if werr := os.WriteFile(filepath.Join(root, ok), []byte("#!/usr/bin/env bash\necho fine\n"), 0o755); werr != nil {
		t.Fatal(werr)
	}
	code, err = RunQuiet(root, ok, nil)
	if code != 0 || err != nil {
		t.Errorf("success run = (%d, %v), want (0, nil)", code, err)
	}
}

func TestRunQuietWithInputFeedsStdin(t *testing.T) {
	root := t.TempDir()
	script := "reader.sh"
	content := "#!/usr/bin/env bash\nread -r line\n[ \"$line\" = \"sekrit\" ] || exit 9\n"
	if err := os.WriteFile(filepath.Join(root, script), []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}

	code, err := RunQuietWithInput(root, script, nil, "sekrit\n")
	if err != nil {
		t.Fatalf("error: %v", err)
	}
	if code != 0 {
		t.Errorf("code = %d, want 0 (stdin not delivered?)", code)
	}
}

func TestRunOutputCapturesStdout(t *testing.T) {
	root := t.TempDir()
	script := "emit.sh"
	if err := os.WriteFile(filepath.Join(root, script), []byte("#!/usr/bin/env bash\necho '{\"x\":1}'\necho noise >&2\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	code, out, err := RunOutput(root, script, nil)
	if code != 0 || err != nil {
		t.Fatalf("= (%d, %v)", code, err)
	}
	if strings.TrimSpace(out) != `{"x":1}` {
		t.Errorf("stdout = %q", out)
	}
}
