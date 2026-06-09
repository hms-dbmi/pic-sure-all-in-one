// End-to-end PTY test: the built binary must start the dashboard on a
// terminal, render its panes, and quit cleanly on 'q' without corrupting
// the terminal (a clean exit implies Bubble Tea's teardown ran).
package smoke

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/creack/pty"
)

func buildBinary(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "pic-sure")
	cmd := exec.Command("go", "build", "-o", bin, "../cmd/pic-sure")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	return bin
}

func repoRoot(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Dir(abs)
}

func TestDashboardStartsAndQuitsUnderPTY(t *testing.T) {
	if os.Getenv("CI") != "" && os.Getenv("PICSURE_PTY_TEST") == "" {
		// PTY behavior on exotic CI runners can be flaky; opt in there.
		t.Skip("set PICSURE_PTY_TEST=1 to run the PTY test in CI")
	}

	bin := buildBinary(t)
	root := repoRoot(t)

	cmd := exec.Command(bin, "dashboard", "--root", root)
	master, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 40, Cols: 120})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = master.Close() }()

	var mu sync.Mutex
	var output bytes.Buffer
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := master.Read(buf)
			if n > 0 {
				mu.Lock()
				output.Write(buf[:n])
				mu.Unlock()
			}
			if err != nil {
				return
			}
		}
	}()

	sawUI := false
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		rendered := output.String()
		mu.Unlock()
		if strings.Contains(rendered, "PIC-SURE") && strings.Contains(rendered, "Services") {
			sawUI = true
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if !sawUI {
		mu.Lock()
		t.Fatalf("dashboard did not render within 15s; output:\n%s", output.String())
	}

	if _, err := master.Write([]byte("q")); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("dashboard exited non-zero after 'q': %v", err)
		}
	case <-time.After(10 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("dashboard did not quit within 10s of 'q'")
	}
}

func TestBareInvocationNonTTYPrintsHelp(t *testing.T) {
	bin := buildBinary(t)
	root := repoRoot(t)

	cmd := exec.Command(bin, "--root", root)
	cmd.Stdin = nil // not a terminal
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bare non-TTY invocation should exit 0: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "Usage:") {
		t.Errorf("expected help output, got:\n%s", out)
	}
}
