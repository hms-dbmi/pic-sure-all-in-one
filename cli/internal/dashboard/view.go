package dashboard

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

var (
	titleStyle    = lipgloss.NewStyle().Bold(true).Padding(0, 1)
	paneStyle     = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
	paneTitle     = lipgloss.NewStyle().Bold(true)
	selectedStyle = lipgloss.NewStyle().Reverse(true)
	okStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	warnStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	badStyle      = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	helpStyle     = lipgloss.NewStyle().Faint(true).Padding(0, 1)
	resultStyle   = lipgloss.NewStyle().Bold(true).Padding(0, 1)
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
	content := m.actionOut.String()
	if m.actionView.Width > 0 {
		content = ansi.Hardwrap(content, m.actionView.Width, true)
	}
	m.actionView.SetContent(content)
	m.actionView.GotoBottom()
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
	case modeConfirm, modePick:
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

	if m.servicesErr != nil {
		b.WriteString(warnStyle.Render("unavailable") + "\n")
		b.WriteString(helpStyle.Render("(docker or .env not ready)"))
	} else if len(m.services) == 0 {
		b.WriteString(helpStyle.Render("no services running"))
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
	footer := helpStyle.Render("ctrl+c interrupt")
	if m.runner == nil {
		title = paneTitle.Render(m.actionName + " — finished")
		footer = resultStyle.Render(m.lastResult) + helpStyle.Render("  esc close")
	}
	return paneStyle.Width(width).Render(title + "\n" + m.actionView.View() + "\n" + footer)
}

func (m *model) formPane() string {
	width := max(m.width-leftWidth-6, 20)
	return paneStyle.Width(width).Render(m.form.View())
}

func (m *model) helpLine() string {
	switch m.mode {
	case modeActing:
		if m.runner == nil {
			return "esc close · pgup/pgdn scroll"
		}
		return "ctrl+c interrupt · pgup/pgdn scroll"
	case modeConfirm, modePick:
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
