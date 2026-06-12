package dashboard

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/contract"
)

func keyMsg(s string) tea.KeyMsg {
	switch s {
	case "esc":
		return tea.KeyMsg(tea.Key{Type: tea.KeyEsc})
	case "ctrl+c":
		return tea.KeyMsg(tea.Key{Type: tea.KeyCtrlC})
	case "up":
		return tea.KeyMsg(tea.Key{Type: tea.KeyUp})
	case "down":
		return tea.KeyMsg(tea.Key{Type: tea.KeyDown})
	default:
		return tea.KeyMsg(tea.Key{Type: tea.KeyRunes, Runes: []rune(s)})
	}
}

// testModel returns a sized model rooted in a temp dir (any spawned helper
// process fails fast and harmlessly there).
func testModel(t *testing.T) *model {
	t.Helper()
	m := newModel(t.TempDir())
	m.width, m.height = 120, 40
	m.layout()
	return m
}

func update(t *testing.T, m *model, msg tea.Msg) (*model, tea.Cmd) {
	t.Helper()
	next, cmd := m.Update(msg)
	nm, ok := next.(*model)
	if !ok {
		t.Fatalf("Update returned %T, want *model", next)
	}
	return nm, cmd
}

func TestActionKeysOpenConfirm(t *testing.T) {
	tests := []struct {
		key         string
		wantName    string
		destructive bool
	}{
		{"u", "update", false},
		{"p", "preflight", false},
		{"m", "migrate", false},
		{"s", "seed-db", false},
		{"R", "reset", true},
		{"X", "uninstall", true},
	}
	for _, tt := range tests {
		t.Run(tt.key, func(t *testing.T) {
			m := testModel(t)
			m, _ = update(t, m, keyMsg(tt.key))
			if m.mode != modeConfirm {
				t.Fatalf("mode = %v, want modeConfirm", m.mode)
			}
			if m.pending == nil || m.pending.Name != tt.wantName {
				t.Fatalf("pending = %+v, want %s", m.pending, tt.wantName)
			}
			if m.pending.Destructive != tt.destructive {
				t.Errorf("destructive = %v, want %v", m.pending.Destructive, tt.destructive)
			}
			if m.form == nil {
				t.Error("confirm form not created")
			}
		})
	}
}

func TestPickerKeyOpensPicker(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("e"))
	if m.mode != modePick {
		t.Fatalf("mode = %v, want modePick", m.mode)
	}
}

func TestRestartRequiresSelectedService(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("r"))
	if m.mode != modeNormal {
		t.Fatal("restart with no services should be a no-op")
	}

	m.services = []contract.ComposeService{{Service: "wildfly"}, {Service: "hpds"}}
	m.selected = 1
	m, _ = update(t, m, keyMsg("r"))
	if m.mode != modeConfirm || m.pending == nil || m.pending.Name != "restart hpds" {
		t.Fatalf("pending = %+v, want restart hpds", m.pending)
	}
}

func TestQuitKeyQuits(t *testing.T) {
	m := testModel(t)
	_, cmd := update(t, m, keyMsg("q"))
	if cmd == nil {
		t.Fatal("q should produce a command")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("q should quit")
	}
}

func TestServicesMsgClampsSelection(t *testing.T) {
	m := testModel(t)
	m.services = []contract.ComposeService{{Service: "a"}, {Service: "b"}, {Service: "c"}}
	m.selected = 2
	m.logSvc = "c" // suppress initial follower spawn

	m, _ = update(t, m, servicesMsg{services: []contract.ComposeService{{Service: "a"}}})
	if m.selected != 0 {
		t.Errorf("selected = %d, want 0 after shrink", m.selected)
	}
}

func TestStaleLogLinesAreDiscarded(t *testing.T) {
	m := testModel(t)
	m.logSession = &logSession{id: 5, cancel: func() {}, lines: make(chan string)}
	m.logSvc = "wildfly"

	m, _ = update(t, m, logLinesMsg{sessionID: 4, lines: []string{"stale line"}})
	if len(m.logLines) != 0 {
		t.Errorf("stale session line was appended: %v", m.logLines)
	}
}

func TestLogLinesCapped(t *testing.T) {
	m := testModel(t)
	ch := make(chan string, 1)
	ch <- "next" // keep waitLines from blocking when the returned cmd runs
	m.logSession = &logSession{id: 1, cancel: func() {}, lines: ch}
	m.logLines = make([]string, maxLogLines)

	m, _ = update(t, m, logLinesMsg{sessionID: 1, lines: []string{"overflow-1", "overflow-2"}})
	if len(m.logLines) != maxLogLines {
		t.Errorf("log lines = %d, want capped at %d", len(m.logLines), maxLogLines)
	}
	if m.logLines[len(m.logLines)-1] != "overflow-2" {
		t.Error("newest line should be kept")
	}
}

func TestWaitLinesBatchesBufferedLines(t *testing.T) {
	ch := make(chan string, 8)
	for _, l := range []string{"a", "b", "c"} {
		ch <- l
	}
	s := &logSession{id: 1, cancel: func() {}, lines: ch}

	msg := s.waitLines()()
	batch, ok := msg.(logLinesMsg)
	if !ok {
		t.Fatalf("got %T, want logLinesMsg", msg)
	}
	if len(batch.lines) != 3 || batch.lines[0] != "a" || batch.lines[2] != "c" {
		t.Errorf("batch = %v, want [a b c] in one message", batch.lines)
	}
}

func TestActionDoneFormatsResultAndRefreshes(t *testing.T) {
	tests := []struct {
		name string
		msg  actions.DoneMsg
		want string
	}{
		{"success", actions.DoneMsg{Code: 0}, "update succeeded (exit 0)"},
		{"failure", actions.DoneMsg{Code: 137}, "update FAILED (exit 137)"},
		{"signal death uses 128+N convention", actions.DoneMsg{Code: 130}, "update FAILED (exit 130)"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := testModel(t)
			m.mode = modeActing
			m.actionName = "update"
			m.runner = &actions.PTYRunner{}

			m, cmd := update(t, m, tt.msg)
			if m.lastResult != tt.want {
				t.Errorf("lastResult = %q, want %q", m.lastResult, tt.want)
			}
			if m.runner != nil {
				t.Error("runner should be cleared")
			}
			if m.mode != modeActing {
				t.Error("pane should stay open until dismissed")
			}
			if cmd == nil {
				t.Error("completion should trigger a services+status refresh")
			}
		})
	}
}

func TestEscClosesFinishedActionPane(t *testing.T) {
	m := testModel(t)
	m.mode = modeActing
	m.runner = nil // finished
	m.actionOut = actions.NewOutputBuffer()

	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeNormal {
		t.Errorf("mode = %v, want modeNormal after esc on finished pane", m.mode)
	}

	// While still running, esc must NOT close the pane.
	m.mode = modeActing
	m.runner = &actions.PTYRunner{}
	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeActing {
		t.Error("esc must not close a pane with a live runner")
	}
}

func TestPtyOutputSanitizedIntoPane(t *testing.T) {
	m := testModel(t)
	m.mode = modeActing
	m.actionOut = actions.NewOutputBuffer()

	// Progress rewrites collapse; CRLF splits lines (PTY semantics).
	m, _ = update(t, m, actions.OutputMsg{Data: []byte("pull:  10%\rpull: 100%\r\ndone\r\n")})
	if got := m.actionOut.String(); got != "pull: 100%\ndone" {
		t.Errorf("sanitized output = %q", got)
	}
}

func TestSelectionMovesAndClamps(t *testing.T) {
	m := testModel(t)
	m.services = []contract.ComposeService{{Service: "a"}, {Service: "b"}}
	m.logSvc = "a" // pretend a follower exists so moves only switch sessions

	m, _ = update(t, m, keyMsg("down"))
	if m.selected != 1 {
		t.Errorf("selected = %d, want 1", m.selected)
	}
	m, _ = update(t, m, keyMsg("down"))
	if m.selected != 1 {
		t.Errorf("selected = %d, want clamped at 1", m.selected)
	}
	m, _ = update(t, m, keyMsg("up"))
	m, _ = update(t, m, keyMsg("up"))
	if m.selected != 0 {
		t.Errorf("selected = %d, want clamped at 0", m.selected)
	}
}

func TestEscInNormalModeEmitsBackMsg(t *testing.T) {
	m := newModel(t.TempDir())
	_, cmd := m.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("esc in normal mode returned no command")
	}
	if _, ok := cmd().(BackMsg); !ok {
		t.Fatalf("esc in normal mode = %T, want BackMsg", cmd())
	}
}

func TestPollInflightGuards(t *testing.T) {
	m := newModel(t.TempDir())
	_, _ = m.Update(servicesTickMsg{})
	if !m.pollingServices {
		t.Fatal("services tick did not mark a poll in flight")
	}
	_, _ = m.Update(statusTickMsg{})
	if !m.pollingStatus {
		t.Fatal("status tick did not mark a poll in flight")
	}
	// Responses clear the flags so the next tick polls again.
	_, _ = m.Update(servicesMsg{})
	if m.pollingServices {
		t.Fatal("services response did not clear the in-flight flag")
	}
	_, _ = m.Update(statusMsg{})
	if m.pollingStatus {
		t.Fatal("status response did not clear the in-flight flag")
	}
}

// frameFits asserts the rendered frame never exceeds the terminal box —
// an overflowing frame makes bubbletea push the UI into scrollback.
func frameFits(t *testing.T, view string, width, height int) {
	t.Helper()
	if h := lipgloss.Height(view); h > height {
		t.Errorf("frame height %d exceeds terminal height %d", h, height)
	}
	for i, line := range strings.Split(view, "\n") {
		if w := lipgloss.Width(line); w > width {
			t.Errorf("frame line %d width %d exceeds terminal width %d", i, w, width)
		}
	}
}

func TestActionPaneFloodKeepsFrameInBox(t *testing.T) {
	m := testModel(t)
	mm, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m = mm.(*model)
	m.mode = modeActing
	m.actionName = "update"
	m.actionOut = actions.NewOutputBuffer()

	var b strings.Builder
	for i := 0; i < 300; i++ {
		fmt.Fprintf(&b, "layer%03d: %s\r\n", i, strings.Repeat("0123456789abcdef ", 12))
	}
	mm, _ = m.Update(actions.OutputMsg{Data: []byte(b.String())})
	m = mm.(*model)

	frameFits(t, m.View(), 100, 30)
}

func TestLogPaneFloodKeepsFrameInBox(t *testing.T) {
	m := testModel(t)
	mm, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m = mm.(*model)

	long := make([]string, 120)
	for i := range long {
		long[i] = strings.Repeat("wildfly | very long docker log line ", 8)
	}
	// Append lines directly and call refreshLogPane (render path under test).
	m.logLines = append(m.logLines, long...)
	if len(m.logLines) > maxLogLines {
		m.logLines = m.logLines[len(m.logLines)-maxLogLines:]
	}
	m.refreshLogPane()

	frameFits(t, m.View(), 100, 30)
}

// TestServicesPaneRowsNoWrap verifies that every service row in the services
// pane occupies exactly one visual line, even with the widest health values.
// The pane is rendered at leftWidth=36 with border(2)+padding(2)=4 overhead,
// giving a content wrap width of 34. Each row is 1 cursor col + formatted
// fields; if the formatted content exceeds 33 visible cols lipgloss wraps and
// the cursor ends up on a different visual line than the service name.
func TestServicesPaneRowsNoWrap(t *testing.T) {
	services := []contract.ComposeService{
		{Service: "very-long-service-name", State: "running", Health: "unhealthy"},
		{Service: "wildfly", State: "running", Health: "healthy"},
		{Service: "hpds", State: "running", Health: "starting"},
		{Service: "short", State: "exited", Health: ""},
	}

	m := testModel(t)
	// Use a small height so Height(max(h-5,8))=8; border+content rows then
	// show wrapping clearly without height-padding masking the problem.
	m.height = 13 // max(13-5, 8) = 8 inner rows = title + 4 services + 3 empty
	m.layout()
	m.services = services
	m.selected = 0

	pane := m.servicesPane()

	// paneStyle uses RoundedBorder (1 col each side) so outer width = leftWidth+2.
	const outerWidth = leftWidth + 2 // 38
	paneLines := strings.Split(pane, "\n")
	for i, line := range paneLines {
		if w := lipgloss.Width(line); w > outerWidth {
			t.Errorf("services pane line %d width %d exceeds outer width %d: %q", i, w, outerWidth, line)
		}
	}

	// Verify no health keyword appears alone on its own inner line (which
	// would happen if a row wraps). Each inner line (between border rows) is
	// "│ <content> │"; we extract content by stripping ANSI then using rune
	// indexing to skip the 2-rune "│ " prefix and 2-rune " │" suffix.
	innerLines := paneLines[1 : len(paneLines)-1] // strip top/bottom border
	healthWords := []string{"unhealthy", "healthy", "starting"}
	for i, rawLine := range innerLines {
		// ansi.Strip removes escape codes; border chars (│, ╭, etc.) are plain Unicode
		plain := ansi.Strip(rawLine)
		runes := []rune(plain)
		// Each inner line: "│" + " " + <content> + " " + "│" = 2+content+2 runes
		if len(runes) >= 4 {
			// Drop "│ " prefix (2 runes) and " │" suffix (2 runes)
			content := strings.TrimRight(string(runes[2:len(runes)-2]), " ")
			for _, hw := range healthWords {
				if content == hw {
					t.Errorf("inner line %d contains only health word %q — row is wrapping: full line %q",
						i, hw, rawLine)
				}
			}
		}
	}
}

// Same huh root cause as the landing/wizard: esc must cancel the dashboard's
// confirm and picker dialogs (the help line advertises "esc cancel").
func TestDashboardEscCancelsConfirmAndPicker(t *testing.T) {
	m := testModel(t)
	m, _ = update(t, m, keyMsg("R")) // reset → typed-word confirm
	if m.mode != modeConfirm {
		t.Fatal("R did not open the confirm")
	}
	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeNormal || m.form != nil {
		t.Errorf("esc did not cancel the confirm: mode=%v", m.mode)
	}

	m, _ = update(t, m, keyMsg("e")) // demo picker
	if m.mode != modePick {
		t.Fatal("e did not open the picker")
	}
	m, _ = update(t, m, keyMsg("esc"))
	if m.mode != modeNormal || m.form != nil {
		t.Errorf("esc did not cancel the picker: mode=%v", m.mode)
	}
}
