package actions

import (
	"os"
	"os/exec"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/creack/pty"

	picexec "github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/exec"
)

// MaxOutput caps retained PTY scrollback (1 MiB), shared by all surfaces.
const MaxOutput = 1 << 20

// OutputMsg carries a batch of PTY output bytes.
type OutputMsg struct{ Data []byte }

// DoneMsg reports the child's exit. Err is non-nil only for start/wait
// failures; Code is the script's exit status (128+N for signal deaths — the
// same mapping the plain CLI runner uses).
type DoneMsg struct {
	Code int
	Err  error
}

// PTYRunner executes an action inside a pseudo-terminal so colored and
// interactive script output renders correctly.
type PTYRunner struct {
	cmd    *exec.Cmd
	master *os.File
	data   chan []byte
}

func StartPTY(root string, act Action, rows, cols int) (*PTYRunner, error) {
	argv := append([]string{filepath.Join(root, act.Script)}, act.Args...)
	cmd := exec.Command("bash", argv...)
	cmd.Dir = root

	master, err := pty.StartWithSize(cmd, &pty.Winsize{
		Rows: uint16(max(rows, 5)),
		Cols: uint16(max(cols, 20)),
	})
	if err != nil {
		return nil, err
	}

	r := &PTYRunner{cmd: cmd, master: master, data: make(chan []byte, 64)}
	go func() {
		defer close(r.data)
		buf := make([]byte, 32*1024)
		for {
			n, err := master.Read(buf)
			if n > 0 {
				chunk := make([]byte, n)
				copy(chunk, buf[:n])
				r.data <- chunk
			}
			if err != nil {
				return // EOF when the child exits
			}
		}
	}()
	return r, nil
}

// WaitData bridges PTY output into Bubble Tea; after the stream closes it
// reaps the child and reports its exit status. Buffered chunks are drained
// into one message so output floods cost one pane rebuild per batch.
func (r *PTYRunner) WaitData() tea.Cmd {
	return func() tea.Msg {
		chunk, ok := <-r.data
		if !ok {
			_ = r.master.Close()
			code, err := picexec.CodeFromWait(r.cmd.Wait())
			return DoneMsg{Code: code, Err: err}
		}
		for len(chunk) < MaxOutput {
			select {
			case more, ok := <-r.data:
				if !ok {
					// Deliver what we have; the next call reports the exit.
					return OutputMsg{Data: chunk}
				}
				chunk = append(chunk, more...)
			default:
				return OutputMsg{Data: chunk}
			}
		}
		return OutputMsg{Data: chunk}
	}
}

func (r *PTYRunner) Resize(rows, cols int) {
	_ = pty.Setsize(r.master, &pty.Winsize{
		Rows: uint16(max(rows, 5)),
		Cols: uint16(max(cols, 20)),
	})
}

// Interrupt delivers ctrl-c through the PTY line discipline so the script's
// whole foreground process group gets SIGINT.
func (r *PTYRunner) Interrupt() {
	_, _ = r.master.Write([]byte{0x03})
}
