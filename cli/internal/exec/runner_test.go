package exec

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
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
