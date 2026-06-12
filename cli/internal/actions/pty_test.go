package actions

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// startSleepPTY launches a real fixture script (a long sleep) through StartPTY
// so Kill() is exercised against an actual PTY child process group.
func startSleepPTY(t *testing.T) *PTYRunner {
	t.Helper()
	root := t.TempDir()
	script := filepath.Join(root, "sleep.sh")
	if err := os.WriteFile(script, []byte("sleep 30\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, err := StartPTY(root, Action{Name: "sleep", Script: "sleep.sh"}, 10, 40)
	if err != nil {
		t.Fatalf("StartPTY: %v", err)
	}
	return r
}

// startPTYScript writes body to a fixture script and starts it through
// StartPTY, returning the runner.
func startPTYScript(t *testing.T, body string, rows, cols int) *PTYRunner {
	t.Helper()
	root := t.TempDir()
	script := filepath.Join(root, "fixture.sh")
	if err := os.WriteFile(script, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	r, err := StartPTY(root, Action{Name: "fixture", Script: "fixture.sh"}, rows, cols)
	if err != nil {
		t.Fatalf("StartPTY: %v", err)
	}
	return r
}

// drainToDone pumps WaitData like the bubbletea runtime until the child's
// DoneMsg arrives (OutputMsg batches may precede it).
func drainToDone(t *testing.T, r *PTYRunner) DoneMsg {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		switch msg := r.WaitData()().(type) {
		case DoneMsg:
			return msg
		case OutputMsg:
			continue
		default:
			t.Fatalf("WaitData returned %T, want OutputMsg or DoneMsg", msg)
		}
	}
	t.Fatal("child did not exit within 10s")
	return DoneMsg{}
}

// drainCollect pumps WaitData to completion, accumulating every OutputMsg
// payload, and returns the concatenated output alongside the terminal DoneMsg.
// Deadline-protected so a wedged child fails the test instead of hanging it.
func drainCollect(t *testing.T, r *PTYRunner) ([]byte, DoneMsg) {
	t.Helper()
	var out []byte
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		switch msg := r.WaitData()().(type) {
		case DoneMsg:
			return out, msg
		case OutputMsg:
			out = append(out, msg.Data...)
		default:
			t.Fatalf("WaitData returned %T, want OutputMsg or DoneMsg", msg)
		}
	}
	t.Fatal("child did not exit within 10s")
	return out, DoneMsg{}
}

// TestPTYRunnerStreamsOutputThenExitCode runs a fixture that prints colored
// output (raw SGR escapes) and then `exit 7` through StartPTY. It asserts the
// output reaches the runtime as OutputMsg batches with the color escapes
// intact, and that the final message is DoneMsg{Code: 7, Err: nil} — the core
// "run a script inside the TUI" path (StartPTY → WaitData batching → EOF →
// CodeFromWait), exercised end-to-end with no docker and no stubs.
func TestPTYRunnerStreamsOutputThenExitCode(t *testing.T) {
	// \033[31m red, \033[0m reset — the escapes a colored script emits and
	// that the PTY must pass through verbatim for the pane to render color.
	body := "printf '\\033[31mRED\\033[0m line one\\n'\n" +
		"printf 'plain line two\\n'\n" +
		"exit 7\n"
	r := startPTYScript(t, body, 10, 40)

	out, done := drainCollect(t, r)

	if done.Err != nil {
		t.Fatalf("DoneMsg.Err = %v, want nil", done.Err)
	}
	if done.Code != 7 {
		t.Errorf("DoneMsg.Code = %d, want 7 (script's exit status)", done.Code)
	}
	// Color escapes survive the PTY round trip.
	if !bytes.Contains(out, []byte("\033[31m")) || !bytes.Contains(out, []byte("\033[0m")) {
		t.Errorf("output missing SGR color escapes; got %q", out)
	}
	if !bytes.Contains(out, []byte("RED")) || !bytes.Contains(out, []byte("plain line two")) {
		t.Errorf("output missing printed text; got %q", out)
	}
}

// TestPTYRunnerInterruptYields130: Interrupt() writes ctrl-c through the PTY
// line discipline, which delivers SIGINT to the foreground process group, so a
// sleeping script dies with the 128+SIGINT (=130) convention and DoneMsg.Err
// stays nil (a signal death is a code, not an error).
func TestPTYRunnerInterruptYields130(t *testing.T) {
	r := startSleepPTY(t)

	// Give the child a moment to install the sleep as the PTY foreground job
	// before delivering the interrupt.
	time.Sleep(150 * time.Millisecond)
	r.Interrupt()

	done := drainToDone(t, r)
	if done.Err != nil {
		t.Fatalf("DoneMsg.Err = %v, want nil (signal death is a code, not an error)", done.Err)
	}
	if done.Code != 130 {
		t.Errorf("DoneMsg.Code = %d, want 130 (128+SIGINT)", done.Code)
	}
}

// TestPTYRunnerResizeMidRunDoesNotDisrupt: Resize() while the child is alive
// must not error or wedge the run — the script completes normally (exit 0)
// afterward and the exit code still propagates.
func TestPTYRunnerResizeMidRunDoesNotDisrupt(t *testing.T) {
	// Print, briefly sleep so the resize lands mid-run, then exit cleanly.
	body := "printf 'before resize\\n'\n" +
		"sleep 0.3\n" +
		"printf 'after resize\\n'\n" +
		"exit 0\n"
	r := startPTYScript(t, body, 10, 40)

	// Resize repeatedly while the child runs; none of these may error or
	// disturb the run (Resize swallows its own error, so we assert via the
	// subsequent clean completion).
	time.Sleep(100 * time.Millisecond)
	r.Resize(24, 80)
	r.Resize(40, 120)

	out, done := drainCollect(t, r)
	if done.Err != nil {
		t.Fatalf("DoneMsg.Err = %v, want nil after a mid-run resize", done.Err)
	}
	if done.Code != 0 {
		t.Errorf("DoneMsg.Code = %d, want 0 (resize must not disrupt a clean exit)", done.Code)
	}
	if !bytes.Contains(out, []byte("after resize")) {
		t.Errorf("output missing post-resize line; got %q", out)
	}
}

// TestPTYRunnerKillTerminatesChild: Kill() SIGKILLs the child's process group,
// so a child that would otherwise run for 30s exits immediately and WaitData
// reports the signal death with the 128+N convention (SIGKILL=9 → 137).
func TestPTYRunnerKillTerminatesChild(t *testing.T) {
	r := startSleepPTY(t)

	r.Kill()
	done := drainToDone(t, r)
	if done.Err != nil {
		t.Fatalf("DoneMsg.Err = %v, want nil (signal death is a code, not an error)", done.Err)
	}
	if done.Code != 137 {
		t.Errorf("DoneMsg.Code = %d, want 137 (128+SIGKILL)", done.Code)
	}

	// Double-Kill: the child is reaped now, so the group send yields ESRCH —
	// a no-op success. Must not panic and must not error-fallback visibly.
	r.Kill()
}

// TestPTYRunnerKillNilProcess: a runner whose cmd never started (Process nil)
// must be a safe no-op — the guard, not a panic.
func TestPTYRunnerKillNilProcess(t *testing.T) {
	r := &PTYRunner{cmd: exec.Command("true")} // never started: Process == nil
	r.Kill()                                   // must not panic
}
