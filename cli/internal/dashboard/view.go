package dashboard

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/styles"
)

var (
	// titleStyle is the top-of-screen header; paneTitle the per-pane headers.
	// Both carry the shared brand color so the dashboard reads as one product
	// with the logo, not a generic table.
	titleStyle    = lipgloss.NewStyle().Bold(true).Foreground(styles.Brand).Padding(0, 1)
	paneStyle     = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
	paneTitle     = lipgloss.NewStyle().Bold(true).Foreground(styles.Brand)
	selectedStyle = lipgloss.NewStyle().Reverse(true)
	// Status colors come from the shared palette (ANSI 2/3/1, theme-remappable).
	okStyle     = styles.OK
	warnStyle   = styles.Warn
	badStyle    = styles.Bad
	helpStyle   = lipgloss.NewStyle().Faint(true).Padding(0, 1)
	resultStyle = lipgloss.NewStyle().Bold(true).Padding(0, 1)
)

// layout recomputes viewport dimensions after a resize.
func (m *model) layout() {
	rightWidth := max(m.width-leftWidth-6, 20)
	logHeight := max(m.height-summaryHeight-7, 3)

	// Viewport content width = styled pane width minus its 2 padding cols.
	m.logView.Width = rightWidth - 2
	m.logView.Height = logHeight

	rows, cols := m.actionPaneSize()
	m.actionView.Width = cols
	m.actionView.Height = rows
	m.refreshActionPane() // re-wrap at the new width
	m.refreshLogPane()
}

// refreshLogPane re-renders the followed logs, hard-wrapped at the viewport
// width so long docker log lines cannot blow the frame out of the terminal.
func (m *model) refreshLogPane() {
	atBottom := m.logView.AtBottom()
	content := strings.Join(m.logLines, "\n")
	if m.logView.Width > 0 {
		content = ansi.Hardwrap(content, m.logView.Width, true)
	}
	m.logView.SetContent(content)
	if atBottom {
		m.logView.GotoBottom()
	}
}

// refreshActionPane re-renders the sanitized action output, hard-wrapped at
// the pane width (ANSI-aware) so long script lines cannot overflow the pane
// and shear the border.
func (m *model) refreshActionPane() {
	if m.actionOut == nil {
		return
	}
	// Autoscroll only when already tailing, so pgup/pgdn scroll-back survives
	// the next output chunk during a chatty run (the modeActing help line
	// advertises this). Same pattern as refreshLogPane and the activity screen.
	atBottom := m.actionView.AtBottom()
	content := m.actionOut.String()
	if m.actionView.Width > 0 {
		content = ansi.Hardwrap(content, m.actionView.Width, true)
	}
	m.actionView.SetContent(content)
	if atBottom {
		m.actionView.GotoBottom()
	}
}

// actionPaneSize is the PTY/viewport geometry: the full right column MINUS
// the pane's 2 columns of padding (paneStyle .Width includes padding; a
// viewport sized to the styled width re-wraps inside the pane and the frame
// outgrows the terminal — bubbletea then scrolls the UI out of view).
func (m *model) actionPaneSize() (rows, cols int) {
	cols = max(m.width-leftWidth-8, 20)
	rows = max(m.height-7, 5)
	return rows, cols
}

func (m *model) View() string {
	if m.width == 0 {
		return "loading..."
	}

	header := titleStyle.Render(m.headerLine())

	var right string
	switch m.mode {
	case modeActing:
		right = m.actionPane()
	case modeConfirm, modePick, modeReset:
		right = m.formPane()
	default:
		right = lipgloss.JoinVertical(lipgloss.Left, m.summaryPane(), m.logPane())
	}

	body := lipgloss.JoinHorizontal(lipgloss.Top, m.servicesPane(), right)

	footer := helpStyle.Render(m.helpLine())
	if m.lastResult != "" && m.mode == modeNormal {
		footer = lipgloss.JoinVertical(lipgloss.Left, resultStyle.Render(m.lastResult), footer)
	}

	return lipgloss.JoinVertical(lipgloss.Left, header, body, footer)
}

func (m *model) headerLine() string {
	project := "picsure"
	extra := ""
	if m.status != nil {
		project = m.status.Env.ComposeProjectName
		extra = fmt.Sprintf("  db:%s auth:%s tag:%s", m.status.Env.DBMode, m.status.Env.AuthMode, m.status.Env.PicsureImageTag)
	}
	return "PIC-SURE — " + project + extra
}

func (m *model) servicesPane() string {
	var b strings.Builder
	b.WriteString(paneTitle.Render("Services") + "\n")

	if m.servicesErr != nil || len(m.services) == 0 {
		b.WriteString(m.servicesEmptyState())
	}

	// Row layout: cursor(1) + service(15) + space(1) + state(7) + space(1) + health(9) = 34
	// = content wrap width. lipgloss .Width() excludes the border (drawn
	// outside it), so wrap width = leftWidth(36) − padding(1+1) = 34.
	// To adjust when leftWidth changes: keep cursor=1, rebalance the three
	// column widths so they (plus 2 separator spaces) sum to leftWidth − 2 − 1.
	// Tradeoff: svcCol=15 clips the real service "pic-sure-logging" (16 chars)
	// to "pic-sure-loggin" — accepted, since 16 + full state(8) + full
	// health(9) + separators cannot fit the 34-col budget.
	const (
		svcCol    = 15
		stateCol  = 7
		healthCol = 9
	)
	for i, s := range m.services {
		health := s.Health
		if health == "" {
			health = "-"
		}
		line := fmt.Sprintf("%-*.*s %-*.*s %-*.*s",
			svcCol, svcCol, s.Service,
			stateCol, stateCol, s.State,
			healthCol, healthCol, health)
		switch {
		case s.State == "running" && (s.Health == "healthy" || s.Health == ""):
			line = okStyle.Render(line)
		case s.State == "running":
			line = warnStyle.Render(line)
		default:
			line = badStyle.Render(line)
		}
		if i == m.selected {
			line = selectedStyle.Render("▸") + line
		} else {
			line = " " + line
		}
		b.WriteString(line + "\n")
	}

	return paneStyle.Width(leftWidth).Height(max(m.height-5, 8)).Render(b.String())
}

// servicesEmptyState returns a cause-specific, actionable message for the
// services pane when no services are listed — replacing the old faint
// dead-end. The cause is read from the state the model actually has: status.sh
// --json (which exits 0 even when docker/.env are not ready) tells us whether
// the daemon is reachable and whether .env exists; servicesErr (an opaque
// compose-ps exec failure) is the fallback when status has not landed yet.
// Messages are kept within the 34-col pane content width (leftWidth-2), wrapped
// to at most two lines and styled as warnings rather than faint help.
func (m *model) servicesEmptyState() string {
	switch {
	case m.status != nil && !m.status.Env.FilePresent:
		// .env missing: nothing is configured yet.
		return warnStyle.Render("Not configured yet") + "\n" +
			warnStyle.Render("run: pic-sure init")
	case m.status != nil && !m.status.Docker.DaemonReachable:
		// Docker daemon down (status.sh saw it, or compose-ps failed for it).
		return warnStyle.Render("Docker is not running") + "\n" +
			warnStyle.Render("start Docker, then: pic-sure up")
	case m.servicesErr != nil && m.status == nil:
		// compose ps failed and status has not landed to disambiguate the cause.
		return warnStyle.Render("Services unavailable") + "\n" +
			warnStyle.Render("check Docker, then: pic-sure up")
	default:
		// Configured, daemon reachable, but nothing is up.
		return warnStyle.Render("No services running") + "\n" +
			warnStyle.Render("start the stack: pic-sure up")
	}
}

func (m *model) summaryPane() string {
	width := max(m.width-leftWidth-6, 20)
	var b strings.Builder
	b.WriteString(paneTitle.Render("Status") + "\n")

	switch {
	case m.statusErr != nil:
		b.WriteString(badStyle.Render(fmt.Sprintf("status.sh --json failed: %v", m.statusErr)))
	case m.status == nil:
		b.WriteString(helpStyle.Render("loading status..."))
	default:
		s := m.status
		envLine := ".env: "
		switch {
		case !s.Env.FilePresent:
			envLine += badStyle.Render("missing — run pic-sure init")
		case s.Env.FileValid != nil && !*s.Env.FileValid:
			envLine += badStyle.Render("INVALID shell syntax")
		default:
			envLine += okStyle.Render("present")
		}
		b.WriteString(envLine + "\n")

		commit := "unresolved"
		if s.ReleaseControl.Commit != nil {
			commit = shortCommit(*s.ReleaseControl.Commit)
		}
		fmt.Fprintf(&b, "release: %s @ %s\n", s.ReleaseControl.Branch, commit)

		clean, dirty, missing := 0, 0, 0
		for _, r := range s.Repos {
			switch r.State {
			case "dirty":
				dirty++
			case "missing":
				missing++
			default:
				clean++
			}
		}
		repoLine := fmt.Sprintf("repos: %d clean", clean)
		if dirty > 0 {
			repoLine += warnStyle.Render(fmt.Sprintf(", %d dirty", dirty))
		}
		if missing > 0 {
			repoLine += helpStyle.Render(fmt.Sprintf(", %d missing", missing))
		}
		b.WriteString(repoLine + "\n")

		dockerLine := "docker: "
		if s.Docker.DaemonReachable {
			dockerLine += okStyle.Render("reachable")
		} else {
			dockerLine += badStyle.Render("unreachable")
		}
		if s.Docker.ComposeConfigValid != nil && !*s.Docker.ComposeConfigValid {
			dockerLine += badStyle.Render("  compose config invalid")
		}
		b.WriteString(dockerLine + "\n")

		migLine := "migrations: "
		switch {
		case !s.Migrations.Checked:
			migLine += helpStyle.Render("not checked")
		case s.Migrations.Ready != nil && *s.Migrations.Ready:
			migLine += okStyle.Render("ready")
		default:
			migLine += badStyle.Render("inputs invalid")
		}
		b.WriteString(migLine)
	}

	return paneStyle.Width(width).Height(summaryHeight - 2).Render(b.String())
}

func (m *model) logPane() string {
	width := max(m.width-leftWidth-6, 20)
	title := paneTitle.Render("Logs")
	if m.logSvc != "" {
		title = paneTitle.Render("Logs — " + m.logSvc)
	}
	return paneStyle.Width(width).Render(title + "\n" + m.logView.View())
}

func (m *model) actionPane() string {
	width := max(m.width-leftWidth-6, 20)
	title := paneTitle.Render("Running: " + m.actionName)

	var footer string
	switch {
	case m.runner == nil:
		// Finished. After a confirmed abort, surface the action's re-run-safety
		// note so the user is never left guessing about state (lastAborted is
		// the latched display flag — the live aborted flag resets on DoneMsg).
		title = paneTitle.Render(m.actionName + " — finished")
		if m.lastAborted && m.actionAbortNote != "" {
			footer = warnStyle.Render("aborted — "+m.actionAbortNote) + helpStyle.Render("  esc close")
		} else {
			footer = resultStyle.Render(m.lastResult) + helpStyle.Render("  esc close")
		}
	case m.confirmingAbort:
		footer = warnStyle.Render(fmt.Sprintf("⚠ %s is still running — abort it? (y/n)", m.actionName))
	case m.killOffered:
		footer = warnStyle.Render("child ignoring interrupt — K: force kill")
	case m.aborted:
		footer = warnStyle.Render("aborting — sent ctrl-c, waiting for the child to exit…")
	default:
		footer = helpStyle.Render("ctrl+c interrupt")
	}
	return paneStyle.Width(width).Render(title + "\n" + m.actionView.View() + "\n" + footer)
}

func (m *model) formPane() string {
	// Styled width minus paneStyle's 2 padding cols = m.width-leftWidth-8,
	// the content width sizeForm feeds the form via actionPaneSize(). Keep
	// these in lockstep or the form re-wraps inside the pane and shears the
	// frame (TestDialogFitsNarrowPane guards this).
	width := max(m.width-leftWidth-6, 20)
	return paneStyle.Width(width).Render(m.form.View())
}

func (m *model) helpLine() string {
	switch m.mode {
	case modeActing:
		switch {
		case m.runner == nil:
			return "esc close · pgup/pgdn scroll"
		case m.confirmingAbort:
			return "y abort · n keep running"
		case m.killOffered:
			return "K force kill · pgup/pgdn scroll"
		case m.aborted:
			return "aborting… · pgup/pgdn scroll"
		default:
			return "ctrl+c interrupt · pgup/pgdn scroll"
		}
	case modeConfirm, modePick, modeReset:
		return "esc cancel"
	}
	return "↑/↓ · r restart · u update · p/m/s · e demo · R reset · X uninstall · pgup/dn scroll · esc · q"
}

func shortCommit(c string) string {
	if len(c) > 8 {
		return c[:8]
	}
	return c
}
