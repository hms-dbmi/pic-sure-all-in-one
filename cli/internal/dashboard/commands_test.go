package dashboard

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestPollCmdNotWedgedByOrphanGrandchild reproduces bug B3: a poll script
// (bash) that spawns a `docker compose`-like grandchild which inherits the
// stdout pipe. When the context fires, killing bash alone leaves the
// grandchild holding the pipe's write end, so cmd.Run blocks on its I/O-copy
// goroutine until EOF — i.e. until the grandchild's own (long) sleep ends.
// pollCmd's process-group kill (and WaitDelay backstop) must bring the whole
// group down so Run returns at the context deadline, not 60s later.
func TestPollCmdNotWedgedByOrphanGrandchild(t *testing.T) {
	root := t.TempDir()

	// fixture: emit a line, spawn a backgrounded sleep that inherits stdout
	// (the orphan-to-be), then block in the foreground so bash is still alive
	// when the context cancels it. Without a group kill, the backgrounded
	// sleep survives bash's death and keeps the stdout pipe open.
	script := "poll-fixture.sh"
	body := "#!/usr/bin/env bash\necho started\nsleep 60 &\nsleep 60\n"
	if err := os.WriteFile(filepath.Join(root, script), []byte(body), 0o755); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	// Short context so the poll is cancelled quickly; the unfixed code would
	// then block ~60s on the orphaned grandchild's open pipe.
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	cmd := pollCmd(ctx, root, script)
	var out bytes.Buffer
	cmd.Stdout = &out

	done := make(chan error, 1)
	go func() { done <- cmd.Run() }()

	select {
	case <-done:
		// Run returned — pipe closed because the group (incl. grandchild) was
		// killed. Good. cmd.Wait already reaped everything we spawned.
	case <-time.After(5 * time.Second):
		// Best-effort cleanup so a wedged grandchild sleep doesn't leak past
		// the test, then fail: this is the unfixed-code behaviour.
		if cmd.Process != nil {
			_ = cmd.Cancel()
		}
		t.Fatalf("poll did not return within 5s of a 500ms-deadline context: "+
			"stdout pipe held open by orphaned grandchild (bug B3). got %q", out.String())
	}
}
