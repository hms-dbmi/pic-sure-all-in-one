package actions

import (
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
	t.Fatal("child did not exit within 10s of Kill()")
	return DoneMsg{}
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
