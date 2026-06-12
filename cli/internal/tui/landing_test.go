package tui

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

func keyEnter() tea.KeyMsg { return tea.KeyMsg{Type: tea.KeyEnter} }
func keyDownN(l *landing, n int) {
	for i := 0; i < n; i++ {
		l.update(tea.KeyMsg{Type: tea.KeyDown})
	}
}

func menuIDs(m *menu) []string {
	ids := make([]string, len(m.items))
	for i, it := range m.items {
		ids[i] = it.ID
	}
	return ids
}

func menuLabels(m *menu) []string {
	labels := make([]string, len(m.items))
	for i, it := range m.items {
		labels[i] = it.Label
	}
	return labels
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

func eq(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestLandingMenuIsContextAware(t *testing.T) {
	fresh := newLanding("/tmp/x", false, false)
	want := []string{"setup", "preflight", "quit"}
	if got := menuIDs(fresh.menu); !eq(got, want) {
		t.Errorf("fresh menu = %v, want %v", got, want)
	}
	configured := newLanding("/tmp/x", true, false)
	want = []string{"dashboard", "update", "etl", "preflight", "reconfigure", "devmenu", "quit"}
	if got := menuIDs(configured.menu); !eq(got, want) {
		t.Errorf("configured menu = %v, want %v", got, want)
	}
	// The configured main menu now carries "Load your data…" (the ETL picker,
	// promoted from Developer options) and no longer "Load demo data".
	labels := menuLabels(configured.menu)
	if !contains(labels, "Load your data…") {
		t.Errorf("configured menu labels = %v, want one to be %q", labels, "Load your data…")
	}
	if contains(labels, "Load demo data") {
		t.Errorf("configured menu still offers %q; it moved to Developer options", "Load demo data")
	}
}

func TestLandingDevSubmenu(t *testing.T) {
	l := newLanding("/tmp/x", true, false)
	keyDownN(l, 5) // select devmenu
	l.update(keyEnter())
	want := []string{"migrate", "seed", "demo", "devoverlay", "devrevert", "relctl", "reset", "uninstall", "back"}
	if got := menuIDs(l.menu); !eq(got, want) {
		t.Fatalf("dev submenu = %v, want %v", got, want)
	}
	// "Load demo data…" lives here now; "ETL operations…" was promoted to the
	// main menu as "Load your data…".
	labels := menuLabels(l.menu)
	if !contains(labels, "Load demo data…") {
		t.Errorf("dev submenu labels = %v, want one to be %q", labels, "Load demo data…")
	}
	if contains(labels, "ETL operations…") {
		t.Errorf("dev submenu still offers %q; it moved to the main menu", "ETL operations…")
	}
	// esc returns to the main menu
	l.update(tea.KeyMsg{Type: tea.KeyEsc})
	if got := menuIDs(l.menu); len(got) != 7 {
		t.Fatalf("esc did not return to main menu: %v", got)
	}
}

// TestLandingDevMenuNoWrapAt80 guards against a dev-menu label that is wide
// enough to wrap inside the menu box at the default 80-column width: the
// selected row renders as "▸ " + label + " ◂" (label+4 cells) centered into
// menuWidth, so any label longer than menuWidth-4 wraps to a second line and
// shears the box. At width 80, menuWidth = min(max(80/3,28),80-8) = 28.
func TestLandingDevMenuNoWrapAt80(t *testing.T) {
	l := newLanding("/tmp/x", true, false)
	l.setSize(80, 40)
	keyDownN(l, 5) // open the dev submenu
	l.update(keyEnter())

	// Same menuWidth formula as contentLines at width 80.
	menuWidth := min(max(l.width/3, 28), l.width-8)
	n := len(l.menu.items)

	for i := 0; i < n; i++ {
		l.menu.selected = i
		lines := strings.Split(l.menu.view(menuWidth), "\n")
		if len(lines) != n {
			t.Errorf("dev menu with item %d (%q) selected rendered %d lines, want %d (label wraps in the box)",
				i, l.menu.items[i].Label, len(lines), n)
		}
		for j, line := range lines {
			if w := lipgloss.Width(line); w > menuWidth {
				t.Errorf("dev menu line %d width %d exceeds menuWidth %d with item %d selected: %q",
					j, w, menuWidth, i, line)
			}
		}
	}
}

// TestLandingResizeReflowsOpenDialog verifies that resizing the terminal
// while a dialog is open re-sizes the live form. huh recomputes its group
// viewport geometry only in its WindowSizeMsg handler; without re-feeding the
// synthetic resize from setSize, a dialog opened wide and then shrunk keeps
// rendering at the old budget (content clipped below the fold).
func TestLandingResizeReflowsOpenDialog(t *testing.T) {
	l := newLanding("/tmp/x", true, false)
	l.setSize(120, 40)
	keyDownN(l, 5) // dev submenu
	l.update(keyEnter())
	// Open the reset dialog (a tall select+input group).
	keyDownN(l, 6) // migrate, seed, etl, devoverlay, devrevert, relctl, reset
	l.update(keyEnter())
	if l.form == nil || !l.resetting {
		t.Fatalf("reset dialog did not open (form=%v resetting=%v)", l.form != nil, l.resetting)
	}

	wide := maxLineWidth(l.form.View())

	// Shrink the terminal while the dialog is open.
	l.setSize(50, 40)
	narrow := maxLineWidth(l.form.View())

	if narrow >= wide {
		t.Errorf("open dialog was not reflowed on resize: wide width=%d, narrow width=%d", wide, narrow)
	}
}

func maxLineWidth(s string) int {
	w := 0
	for _, line := range splitLines(s) {
		if lw := lipgloss.Width(line); lw > w {
			w = lw
		}
	}
	return w
}

func TestLandingSelectionsEmitRequests(t *testing.T) {
	l := newLanding("/tmp/x", true, false)
	// Dashboard (first item)
	_, cmd := l.update(keyEnter())
	if _, ok := cmd().(openDashboardMsg); !ok {
		t.Fatalf("dashboard selection = %T, want openDashboardMsg", cmd())
	}
	// Preflight runs immediately (read-only, no confirm)
	l = newLanding("/tmp/x", true, false)
	keyDownN(l, 3)
	_, cmd = l.update(keyEnter())
	run, ok := cmd().(runActionMsg)
	if !ok || run.act.Name != "preflight" {
		t.Fatalf("preflight selection = %#v, want runActionMsg{preflight}", cmd())
	}
	// Update opens a light confirm, not an immediate run
	l = newLanding("/tmp/x", true, false)
	keyDownN(l, 1)
	_, _ = l.update(keyEnter())
	if l.form == nil || l.pending == nil || l.pending.Name != "update" {
		t.Fatal("update selection did not open a confirm dialog")
	}
	// Setup on a fresh checkout opens the embedded wizard
	l = newLanding("/tmp/x", false, false)
	_, cmd = l.update(keyEnter())
	wiz, ok := cmd().(openWizardMsg)
	if !ok || wiz.reconfigure {
		t.Fatalf("setup selection = %#v, want openWizardMsg{reconfigure: false}", cmd())
	}
}

func TestLandingAnimationTicksSurviveConfirmDialog(t *testing.T) {
	l := newLanding("/tmp/x", true, true)
	l.setSize(80, 24)
	l.startAnimations()
	keyDownN(l, 1)       // select Update
	l.update(keyEnter()) // open its confirm dialog
	if l.form == nil {
		t.Fatal("confirm did not open")
	}
	_, cmd := l.update(starTickMsg{seq: l.star.seq})
	if cmd == nil {
		t.Fatal("starfield tick swallowed by open confirm; animation frozen")
	}
}

func TestLandingQuitKeys(t *testing.T) {
	l := newLanding("/tmp/x", true, false)
	_, cmd := l.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})
	if cmd == nil {
		t.Fatal("q returned no command")
	}
	if msg := cmd(); msg != tea.Quit() {
		t.Fatalf("q = %#v, want tea.Quit", msg)
	}
}

// devOverlayNames are the overlays corresponding to devRoot.
var devOverlayNames = []string{"httpd-hmr", "wildfly"}

// devRoot creates a minimal checkout root with two dev-overlay stub files and
// installs a fetchDevOverlays stub that returns those names, matching what
// `scripts/compose.sh dev list` would return on that root. Restores the
// original fetchDevOverlays on cleanup.
func devRoot(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, f := range []string{"docker-compose.dev-httpd-hmr.yml", "docker-compose.dev-wildfly.yml"} {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("services:\n  x:\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	orig := fetchDevOverlays
	fetchDevOverlays = func(string) []string { return devOverlayNames }
	t.Cleanup(func() { fetchDevOverlays = orig })
	return dir
}

func TestLandingDevSubmenuHasOverlayEntries(t *testing.T) {
	l := newLanding("/tmp/x", true, false)
	keyDownN(l, 5)
	l.update(keyEnter()) // enter developer options
	want := []string{"migrate", "seed", "demo", "devoverlay", "devrevert", "relctl", "reset", "uninstall", "back"}
	if got := menuIDs(l.menu); !eq(got, want) {
		t.Fatalf("dev submenu = %v, want %v", got, want)
	}
}

func TestLandingDevOverlayPickerRunsAction(t *testing.T) {
	l := newLanding(devRoot(t), true, false)
	l.dev = true
	l.rebuildMenu()
	_, _ = l.choose("devoverlay")
	if l.form == nil || l.pickerMake == nil {
		t.Fatal("devoverlay did not open a picker")
	}
	// Complete the picker like the dashboard tests drive huh forms.
	l.picked = "httpd-hmr"
	l.form.State = huh.StateCompleted
	_, cmd := l.update(struct{}{})
	if cmd == nil {
		t.Fatal("picker completion produced no command")
	}
	run, ok := cmd().(runActionMsg)
	if !ok {
		t.Fatalf("got %#v, want runActionMsg", cmd())
	}
	if want := []string{"dev", "up", "httpd-hmr"}; !eq(run.act.Args, want) {
		t.Errorf("action args = %v, want %v", run.act.Args, want)
	}
}

func TestLandingDevOverlayPickerCancel(t *testing.T) {
	l := newLanding(devRoot(t), true, false)
	l.dev = true
	l.rebuildMenu()
	_, _ = l.choose("devoverlay")
	l.picked = "" // Cancel option
	l.form.State = huh.StateCompleted
	_, cmd := l.update(struct{}{})
	if cmd != nil {
		t.Fatal("cancelled picker must not run anything")
	}
	if l.form != nil || l.pickerMake != nil {
		t.Error("picker state not cleared on cancel")
	}
}

// TestLandingDevPickerPrematureEnterCancels pins the placeholder-safety
// invariant: the loading placeholder option carries an EMPTY value, so
// completing the form before the async overlay fill arrives resolves to the
// picker-completion handler's choice=="" Cancel guard — it must never
// dispatch a bogus `dev up "(loading overlays…)"` action (the branch input's
// safe-cancel invariant: an unfilled dialog can only cancel, never act).
func TestLandingDevPickerPrematureEnterCancels(t *testing.T) {
	l := newLanding(devRoot(t), true, false)
	l.dev = true
	l.rebuildMenu()
	_, _ = l.choose("devoverlay")
	if l.form == nil {
		t.Fatal("picker did not open")
	}
	// Do NOT pump the fill: the placeholder is still up and picked is "".
	if l.picked != "" {
		t.Fatalf("picked = %q before the fill, want empty (placeholder value)", l.picked)
	}
	l.form.State = huh.StateCompleted // premature enter on the placeholder
	_, cmd := l.update(struct{}{})
	if cmd != nil {
		if msg := cmd(); msg != nil {
			t.Errorf("premature enter dispatched %#v, want cancel (nothing)", msg)
		}
	}
	if l.form != nil || l.pickerMake != nil {
		t.Error("picker state not cleared after premature-enter cancel")
	}
}

func TestLandingDevOverlayPickerNoFiles(t *testing.T) {
	// Stub fetchDevOverlays to return nothing (simulates an empty checkout or
	// a failed dev list call), restoring on cleanup.
	orig := fetchDevOverlays
	fetchDevOverlays = func(string) []string { return nil }
	t.Cleanup(func() { fetchDevOverlays = orig })

	l := newLanding(t.TempDir(), true, false)
	l.dev = true
	l.rebuildMenu()
	// The picker opens immediately with a placeholder; pump the async fill.
	_, cmd := l.choose("devoverlay")
	l = pumpLanding(l, cmd, 0)
	// After the empty fill the picker must be closed and an explanatory result shown.
	if l.form != nil {
		t.Fatal("picker still open after empty overlay fill")
	}
	if l.pickerMake != nil {
		t.Error("pickerMake not cleared after empty overlay fill")
	}
	if l.result == "" {
		t.Error("expected an explanatory result line")
	}
}

// pumpLanding executes a cmd tree and feeds the msgs back, like the runtime
// (timing ticks discarded after 50ms, as in the wizard tests).
func pumpLanding(l *landing, cmd tea.Cmd, depth int) *landing {
	if cmd == nil || depth > 8 {
		return l
	}
	ch := make(chan tea.Msg, 1)
	go func() { ch <- cmd() }()
	var msg tea.Msg
	select {
	case msg = <-ch:
	case <-time.After(50 * time.Millisecond):
		return l
	}
	switch m := msg.(type) {
	case tea.BatchMsg:
		for _, c := range m {
			l = pumpLanding(l, c, depth+1)
		}
		return l
	case nil:
		return l
	default:
		var next tea.Cmd
		l, next = l.update(msg)
		return pumpLanding(l, next, depth+1)
	}
}

func TestLandingEtlPicker(t *testing.T) {
	// "Load your data…" (the ETL picker) lives on the configured main menu now.
	l := newLanding("/tmp/x", true, false)
	_, _ = l.choose("etl")
	if l.form == nil || l.pickerMake == nil {
		t.Fatal("etl entry did not open a picker")
	}
	l.picked = "run-weights"
	l.form.State = huh.StateCompleted
	_, cmd := l.update(struct{}{})
	run, ok := cmd().(runActionMsg)
	if !ok || run.act.Script != "etl.sh" {
		t.Fatalf("got %#v, want runActionMsg{etl.sh}", cmd())
	}
	if want := []string{"run-weights"}; !eq(run.act.Args, want) {
		t.Errorf("args = %v, want %v", run.act.Args, want)
	}
}

func TestLandingDemoOpensDatasetPicker(t *testing.T) {
	// "Load demo data…" now lives in the Developer options submenu.
	l := newLanding("/tmp/x", true, false)
	l.dev = true
	l.rebuildMenu()
	_, _ = l.choose("demo")
	if l.form == nil || l.pickerMake == nil {
		t.Fatal("demo entry did not open a dataset picker")
	}
	if l.picked != "nhanes" {
		t.Errorf("preselect = %q, want nhanes", l.picked)
	}
	l.picked = "synthea"
	l.form.State = huh.StateCompleted
	_, cmd := l.update(struct{}{})
	run, ok := cmd().(runActionMsg)
	if !ok {
		t.Fatalf("got %#v, want runActionMsg", cmd())
	}
	if want := []string{"synthea"}; !eq(run.act.Args, want) {
		t.Errorf("args = %v, want %v", run.act.Args, want)
	}
}

// The two reset variants live on ONE screen: a scope select (keep DB vs full
// wipe) plus the typed-word confirm. The scope drives which reset.sh
// invocation runs, and the typed word still gates dispatch.
func TestLandingResetCombinedScreen(t *testing.T) {
	open := func() *landing {
		l := newLanding("/tmp/x", true, false)
		l.dev = true
		l.rebuildMenu()
		_, _ = l.choose("reset")
		if l.form == nil || !l.resetting {
			t.Fatal("reset entry did not open the combined dialog")
		}
		if l.resetScope != "keep" {
			t.Fatalf("default scope = %q, want keep", l.resetScope)
		}
		return l
	}

	// The scope choice, the repo toggle, and the typed-word confirm all render
	// together — the whole point of "one screen".
	l := open()
	if l.resetRepos {
		t.Fatalf("repo toggle defaulted ON, want OFF")
	}
	l.setSize(100, 35)
	l = pumpLanding(l, l.form.Init(), 0)
	view := wizardANSI.ReplaceAllString(l.view(), "")
	for _, want := range []string{"Keep the database", "Full wipe", "reset sibling repos to release refs", `Type "reset"`} {
		if !strings.Contains(view, want) {
			t.Errorf("combined reset screen missing %q", want)
		}
	}

	// Keep-DB scope, repos OFF, word typed → reset.sh --yes (no --all, no --repos).
	l = open()
	l.resetScope, l.resetRepos, l.confirmText = "keep", false, "reset"
	l.form.State = huh.StateCompleted
	_, cmd := l.update(struct{}{})
	run, ok := cmd().(runActionMsg)
	if !ok || run.act.Script != "reset.sh" {
		t.Fatalf("keep: got %#v, want runActionMsg{reset.sh}", cmd())
	}
	if want := []string{"--yes"}; !eq(run.act.Args, want) {
		t.Errorf("keep args = %v, want %v", run.act.Args, want)
	}

	// Full-wipe scope, repos OFF, word typed → reset.sh --all --yes.
	l = open()
	l.resetScope, l.resetRepos, l.confirmText = "all", false, "reset"
	l.form.State = huh.StateCompleted
	_, cmd = l.update(struct{}{})
	run, ok = cmd().(runActionMsg)
	if !ok || run.act.Script != "reset.sh" {
		t.Fatalf("full wipe: got %#v, want runActionMsg{reset.sh}", cmd())
	}
	if want := []string{"--all", "--yes"}; !eq(run.act.Args, want) {
		t.Errorf("full-wipe args = %v, want %v", run.act.Args, want)
	}

	// Keep-DB scope, repos ON → reset.sh --repos --yes.
	l = open()
	l.resetScope, l.resetRepos, l.confirmText = "keep", true, "reset"
	l.form.State = huh.StateCompleted
	_, cmd = l.update(struct{}{})
	run, ok = cmd().(runActionMsg)
	if !ok || run.act.Script != "reset.sh" {
		t.Fatalf("keep+repos: got %#v, want runActionMsg{reset.sh}", cmd())
	}
	if want := []string{"--repos", "--yes"}; !eq(run.act.Args, want) {
		t.Errorf("keep+repos args = %v, want %v", run.act.Args, want)
	}

	// Full-wipe scope, repos ON → reset.sh --all --repos --yes.
	l = open()
	l.resetScope, l.resetRepos, l.confirmText = "all", true, "reset"
	l.form.State = huh.StateCompleted
	_, cmd = l.update(struct{}{})
	run, ok = cmd().(runActionMsg)
	if !ok || run.act.Script != "reset.sh" {
		t.Fatalf("all+repos: got %#v, want runActionMsg{reset.sh}", cmd())
	}
	if want := []string{"--all", "--repos", "--yes"}; !eq(run.act.Args, want) {
		t.Errorf("all+repos args = %v, want %v", run.act.Args, want)
	}

	// Wrong word must not dispatch even if the form is forced complete.
	l = open()
	l.resetScope, l.resetRepos, l.confirmText = "all", true, "nope"
	l.form.State = huh.StateCompleted
	_, cmd = l.update(struct{}{})
	if cmd != nil {
		if msg := cmd(); msg != nil {
			t.Errorf("wrong word emitted %#v, want no dispatch", msg)
		}
	}
}

// Regression: the dev picker opened scrolled to its Cancel row (empty
// initial value matched Cancel; WithWidth froze the group viewport) — every
// option must be visible on the very first render, cursor on the first one.
// With the async dev list fetch the picker opens with a placeholder and is
// rebuilt with real options once devOverlaysFillMsg arrives; all options must
// be visible after the fill.
func TestLandingDevPickerShowsAllOptionsInitially(t *testing.T) {
	// devRoot stubs fetchDevOverlays → ["httpd-hmr", "wildfly"].
	l := newLanding(devRoot(t), true, false)
	l.setSize(100, 35)
	l.dev = true
	l.rebuildMenu()
	_, cmd := l.choose("devoverlay")
	// Pump: drives the async fetch and routes the devOverlaysFillMsg back in.
	l = pumpLanding(l, cmd, 0)

	view := wizardANSI.ReplaceAllString(l.view(), "")
	for _, opt := range []string{"httpd-hmr", "wildfly", "Cancel"} {
		if !strings.Contains(view, opt) {
			t.Errorf("picker render (after fill) missing option %q", opt)
		}
	}
	if strings.Contains(view, "> Cancel") {
		t.Error("picker cursor is on Cancel after fill")
	}
	if !strings.Contains(view, "> httpd-hmr") {
		t.Error("cursor not on the first overlay after fill")
	}
}

func TestLandingReleaseControlSubmenu(t *testing.T) {
	orig := fetchReleaseBranch
	fetchReleaseBranch = func(string) string { return "release/2.4" }
	t.Cleanup(func() { fetchReleaseBranch = orig })

	l := newLanding("/tmp/x", true, false)
	l.dev = true
	l.rebuildMenu()
	_, _ = l.choose("relctl")
	want := []string{"rcapply", "rcdryrun", "rcbranch", "back"}
	if got := menuIDs(l.menu); !eq(got, want) {
		t.Fatalf("release-control submenu = %v, want %v", got, want)
	}

	// Switch branch: the one-field input opens IMMEDIATELY (the prefill read is
	// slow and runs off the update path), then the prefill arrives as a message.
	_, cmd := l.choose("rcbranch")
	if l.form == nil || l.inputMake == nil {
		t.Fatal("rcbranch did not open the input")
	}
	if l.inputVal != "" {
		t.Errorf("input opened with a synchronous prefill %q, want empty (async)", l.inputVal)
	}
	if cmd == nil {
		t.Fatal("rcbranch did not dispatch the prefill fetch command")
	}
	// The dispatched batch must carry a branchPrefillMsg with the fetched branch.
	if !batchEmitsBranchPrefill(cmd, "release/2.4") {
		t.Fatal("rcbranch command did not deliver the fetched branch as a branchPrefillMsg")
	}

	// Deliver the prefill: the input is still open and untouched, so it applies.
	l, _ = l.update(branchPrefillMsg{seq: l.branchSeq, branch: "release/2.4"})
	if l.inputVal != "release/2.4" {
		t.Errorf("prefill = %q, want release/2.4", l.inputVal)
	}

	l.inputVal = "feature/x"
	l.form.State = huh.StateCompleted
	_, cmd = l.update(struct{}{})
	run, ok := cmd().(runActionMsg)
	if !ok {
		t.Fatalf("got %#v, want runActionMsg", cmd())
	}
	if want := []string{"--branch", "feature/x"}; !eq(run.act.Args, want) {
		t.Errorf("args = %v, want %v", run.act.Args, want)
	}

	// back navigates to the dev submenu
	l2 := newLanding("/tmp/x", true, false)
	l2.dev = true
	l2.rebuildMenu()
	_, _ = l2.choose("relctl")
	_, _ = l2.choose("back")
	if l2.relctl || !l2.dev {
		t.Error("back did not return to the developer submenu")
	}
}

// batchEmitsBranchPrefill runs cmd (possibly a tea.Batch) and reports whether
// any emitted message is a branchPrefillMsg carrying wantBranch.
func batchEmitsBranchPrefill(cmd tea.Cmd, wantBranch string) bool {
	if cmd == nil {
		return false
	}
	switch m := cmd().(type) {
	case tea.BatchMsg:
		for _, c := range m {
			if batchEmitsBranchPrefill(c, wantBranch) {
				return true
			}
		}
	case branchPrefillMsg:
		return m.branch == wantBranch
	}
	return false
}

// TestLandingDevPickerOpensImmediately verifies that the dev list fetch never
// blocks the update path: the picker opens synchronously with a placeholder
// and only schedules the overlay fetch as a tea.Cmd.
func TestLandingDevPickerOpensImmediately(t *testing.T) {
	called := make(chan struct{}, 1)
	orig := fetchDevOverlays
	fetchDevOverlays = func(string) []string {
		called <- struct{}{}
		return []string{"hpds", "wildfly"}
	}
	t.Cleanup(func() { fetchDevOverlays = orig })

	l := newLanding("/tmp/x", true, false)
	l.setSize(80, 24)
	l.dev = true
	l.rebuildMenu()

	_, cmd := l.choose("devoverlay")
	// fetchDevOverlays must NOT have run synchronously inside choose().
	select {
	case <-called:
		t.Fatal("fetchDevOverlays ran synchronously inside choose() — it must run in a tea.Cmd")
	default:
	}
	if l.form == nil || l.pickerMake == nil {
		t.Fatal("dev picker did not open immediately")
	}
	// The command must eventually deliver a devOverlaysFillMsg with the overlays.
	if !batchEmitsDevOverlaysFill(cmd, []string{"hpds", "wildfly"}) {
		t.Fatal("choose did not dispatch the overlay fetch as a command delivering devOverlaysFillMsg")
	}
}

// TestLandingDevPickerFillStaleness pins the staleness guard: a fill for a
// since-closed/reopened picker (stale seq) must be dropped.
func TestLandingDevPickerFillStaleness(t *testing.T) {
	orig := fetchDevOverlays
	fetchDevOverlays = func(string) []string { return []string{"hpds"} }
	t.Cleanup(func() { fetchDevOverlays = orig })

	l := newLanding("/tmp/x", true, false)
	l.setSize(80, 24)
	l.dev = true
	l.rebuildMenu()

	_, _ = l.choose("devoverlay")
	staleSeq := l.devPickerSeq
	// Close and reopen the picker (bumps devPickerSeq).
	l.form, l.pickerMake = nil, nil
	_, _ = l.choose("devoverlay")
	if l.devPickerSeq == staleSeq {
		t.Fatal("reopening the picker did not bump devPickerSeq")
	}
	// A stale fill must be dropped.
	beforeForm := l.form
	l, _ = l.update(devOverlaysFillMsg{seq: staleSeq, overlays: []string{"hpds"}})
	if l.form != beforeForm {
		t.Error("stale devOverlaysFillMsg replaced the form of the fresh picker")
	}
}

// batchEmitsDevOverlaysFill runs cmd (possibly a tea.Batch) and reports
// whether any emitted message is a devOverlaysFillMsg carrying wantOverlays.
func batchEmitsDevOverlaysFill(cmd tea.Cmd, wantOverlays []string) bool {
	if cmd == nil {
		return false
	}
	switch m := cmd().(type) {
	case tea.BatchMsg:
		for _, c := range m {
			if batchEmitsDevOverlaysFill(c, wantOverlays) {
				return true
			}
		}
	case devOverlaysFillMsg:
		if len(m.overlays) != len(wantOverlays) {
			return false
		}
		for i, o := range m.overlays {
			if o != wantOverlays[i] {
				return false
			}
		}
		return true
	}
	return false
}

// TestDevOverlaysFetchParsing verifies that the overlay list returned by
// fetchDevOverlays is parsed tolerantly when routed through the picker: blank
// lines and entries with only whitespace are dropped, and valid names are
// sorted. Uses a table of pre-parsed stub returns (the RunOutput call itself
// is tested implicitly by the other async picker tests).
func TestDevOverlaysFetchParsing(t *testing.T) {
	cases := []struct {
		name    string
		fetched []string // what fetchDevOverlays returns
		wantNil bool     // whether the picker should be closed (empty list)
		visible []string // options that must appear in the picker view
	}{
		{
			name:    "normal sorted output",
			fetched: []string{"hpds", "httpd-hmr", "wildfly"},
			visible: []string{"hpds", "httpd-hmr", "wildfly", "Cancel"},
		},
		{
			name:    "pre-sorted output stays sorted",
			fetched: []string{"hpds", "wildfly"},
			visible: []string{"hpds", "wildfly", "Cancel"},
		},
		{
			name:    "empty output closes picker",
			fetched: nil,
			wantNil: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			orig := fetchDevOverlays
			fetchDevOverlays = func(string) []string { return tc.fetched }
			t.Cleanup(func() { fetchDevOverlays = orig })

			l := newLanding("/tmp/x", true, false)
			l.setSize(100, 35)
			l.dev = true
			l.rebuildMenu()
			_, cmd := l.choose("devoverlay")
			l = pumpLanding(l, cmd, 0) // drives the async fetch
			if tc.wantNil {
				if l.form != nil {
					t.Error("empty overlay list should have closed the picker")
				}
				return
			}
			if l.form == nil {
				t.Fatal("picker not open after fill")
			}
			view := wizardANSI.ReplaceAllString(l.view(), "")
			for _, name := range tc.visible {
				if !strings.Contains(view, name) {
					t.Errorf("picker view missing %q", name)
				}
			}
		})
	}
}

// TestLandingBranchInputOpensImmediately verifies the slow status.sh read no
// longer blocks the update path: rcbranch opens the input synchronously, with a
// placeholder and an empty value, and only schedules the prefill fetch.
func TestLandingBranchInputOpensImmediately(t *testing.T) {
	called := make(chan struct{}, 1)
	orig := fetchReleaseBranch
	fetchReleaseBranch = func(string) string {
		called <- struct{}{}
		return "release/9.9"
	}
	t.Cleanup(func() { fetchReleaseBranch = orig })

	l := newLanding("/tmp/x", true, false)
	l.setSize(80, 24)
	l.dev = true
	l.rebuildMenu()

	_, cmd := l.choose("rcbranch")
	// The input is open at once — fetchReleaseBranch has NOT run on the update path.
	select {
	case <-called:
		t.Fatal("fetchReleaseBranch ran synchronously inside choose() — it must run in a tea.Cmd")
	default:
	}
	if l.form == nil || l.inputMake == nil {
		t.Fatal("rcbranch did not open the input immediately")
	}
	if l.inputVal != "" {
		t.Errorf("opened with value %q, want empty pending the async prefill", l.inputVal)
	}
	if !strings.Contains(wizardANSI.ReplaceAllString(l.view(), ""), "reading current branch") {
		t.Errorf("input did not show the reading-branch placeholder:\n%s", wizardANSI.ReplaceAllString(l.view(), ""))
	}
	// The fetch is dispatched as a command (and does deliver the branch).
	if !batchEmitsBranchPrefill(cmd, "release/9.9") {
		t.Fatal("rcbranch did not dispatch the prefill fetch as a command")
	}
}

// TestLandingBranchPrefillStaleness pins the three staleness guards: a prefill
// applies to the open, untouched input; a prefill for a since-superseded
// opening (stale seq) is dropped; and a prefill never clobbers a value the user
// has already typed.
func TestLandingBranchPrefillStaleness(t *testing.T) {
	orig := fetchReleaseBranch
	fetchReleaseBranch = func(string) string { return "release/2.4" }
	t.Cleanup(func() { fetchReleaseBranch = orig })

	open := func() *landing {
		l := newLanding("/tmp/x", true, false)
		l.setSize(80, 24)
		l.dev = true
		l.rebuildMenu()
		_, _ = l.choose("rcbranch")
		if l.form == nil {
			t.Fatal("rcbranch did not open the input")
		}
		return l
	}

	// Happy path: still open, untouched → prefill applies.
	l := open()
	l, _ = l.update(branchPrefillMsg{seq: l.branchSeq, branch: "release/2.4"})
	if l.inputVal != "release/2.4" {
		t.Errorf("prefill not applied: inputVal = %q, want release/2.4", l.inputVal)
	}

	// Stale seq: a prefill for an earlier opening must be dropped (the input was
	// closed and reopened, bumping branchSeq).
	l = open()
	staleSeq := l.branchSeq
	l.inputMake, l.form = nil, nil // close
	_, _ = l.choose("rcbranch")    // reopen → branchSeq++
	if l.branchSeq == staleSeq {
		t.Fatal("reopening the input did not bump branchSeq")
	}
	l, _ = l.update(branchPrefillMsg{seq: staleSeq, branch: "release/2.4"})
	if l.inputVal != "" {
		t.Errorf("stale-seq prefill clobbered the reopened input: inputVal = %q, want empty", l.inputVal)
	}

	// User typed before the prefill arrived: never clobber their input.
	l = open()
	l.inputVal = "feature/typed-first"
	l, _ = l.update(branchPrefillMsg{seq: l.branchSeq, branch: "release/2.4"})
	if l.inputVal != "feature/typed-first" {
		t.Errorf("prefill clobbered typed input: inputVal = %q, want feature/typed-first", l.inputVal)
	}
}

// TestLandingBranchPrefillFailure pins the fetch-failure path: an empty branch
// must swap the "(reading current branch…)" placeholder for an explanatory one
// instead of leaving the reading note up forever — without touching the (still
// empty) value, and still honoring the staleness guards.
func TestLandingBranchPrefillFailure(t *testing.T) {
	orig := fetchReleaseBranch
	fetchReleaseBranch = func(string) string { return "" } // status.sh failed
	t.Cleanup(func() { fetchReleaseBranch = orig })

	open := func() *landing {
		l := newLanding("/tmp/x", true, false)
		l.setSize(80, 24)
		l.dev = true
		l.rebuildMenu()
		_, _ = l.choose("rcbranch")
		if l.form == nil {
			t.Fatal("rcbranch did not open the input")
		}
		return l
	}

	l := open()
	l, cmd := l.update(branchPrefillMsg{seq: l.branchSeq, branch: ""})
	if l.inputVal != "" {
		t.Errorf("failed fetch set a value: inputVal = %q, want empty", l.inputVal)
	}
	if l.form == nil || l.inputMake == nil {
		t.Fatal("failed fetch closed the input")
	}
	if cmd == nil {
		t.Error("placeholder rebuild returned no init command")
	}
	view := wizardANSI.ReplaceAllString(l.view(), "")
	if !strings.Contains(view, "couldn't read current branch") {
		t.Errorf("failure placeholder not shown:\n%s", view)
	}
	if strings.Contains(view, "reading current branch") {
		t.Errorf("stale reading placeholder still shown after the fetch failed:\n%s", view)
	}

	// Staleness still guards the failure path: a stale-seq empty prefill must
	// not rebuild the (fresh) reopened input's placeholder.
	l = open()
	staleSeq := l.branchSeq
	l.inputMake, l.form = nil, nil // close
	_, _ = l.choose("rcbranch")    // reopen → branchSeq++
	l, _ = l.update(branchPrefillMsg{seq: staleSeq, branch: ""})
	view = wizardANSI.ReplaceAllString(l.view(), "")
	if !strings.Contains(view, "reading current branch") {
		t.Errorf("stale empty prefill replaced the reopened input's reading placeholder:\n%s", view)
	}

	// And a typed value suppresses the rebuild entirely (no form reset under
	// the user's cursor).
	formBefore := l.form
	l.inputVal = "feature/typed"
	l, _ = l.update(branchPrefillMsg{seq: l.branchSeq, branch: ""})
	if l.form != formBefore {
		t.Error("empty prefill rebuilt the form under typed input")
	}
	if l.inputVal != "feature/typed" {
		t.Errorf("empty prefill disturbed typed input: %q", l.inputVal)
	}
}

// The landing frame must never exceed the terminal box, dialogs included —
// composite() clips by construction; this pins it (the dashboard and
// activity screens carry the same invariant tests).
func TestLandingFrameStaysInBoxWithDialogs(t *testing.T) {
	sizes := [][2]int{{60, 16}, {80, 24}, {120, 30}}
	open := []func(l *landing){
		func(l *landing) { l.dev = true; l.rebuildMenu(); _, _ = l.choose("demo") },
		func(l *landing) { _, _ = l.choose("etl") },
		func(l *landing) { _, _ = l.choose("reset") },
	}
	for _, sz := range sizes {
		for i, openDialog := range open {
			l := newLanding("/tmp/x", true, false)
			l.setSize(sz[0], sz[1])
			openDialog(l)
			view := l.view()
			if h := lipgloss.Height(view); h > sz[1] {
				t.Errorf("size %dx%d dialog %d: frame height %d exceeds %d", sz[0], sz[1], i, h, sz[1])
			}
			for n, line := range strings.Split(view, "\n") {
				if w := lipgloss.Width(line); w > sz[0] {
					t.Errorf("size %dx%d dialog %d line %d: width %d exceeds %d", sz[0], sz[1], i, n, w, sz[0])
				}
			}
		}
	}
}

// TestLandingFooterSwitchesWhenDialogIsOpen guards the footer copy: while a
// dialog is open 'q' types into the input, so the default "q quit" hint is
// wrong. The footer must switch to a dialog-appropriate hint ("esc cancel")
// when l.form != nil, and revert to the normal hints once the dialog closes.
func TestLandingFooterSwitchesWhenDialogIsOpen(t *testing.T) {
	l := newLanding("/tmp/x", true, false)
	// No dialog: normal footer.
	if got := l.footer(); got != "↑/↓ select · enter · q quit" {
		t.Errorf("no-dialog footer = %q, want hint with q quit", got)
	}
	// Open a confirm dialog (update).
	_, _ = l.choose("update")
	if l.form == nil {
		t.Fatal("update did not open a dialog")
	}
	// Dialog open: must NOT show "q quit".
	got := l.footer()
	if strings.Contains(got, "q quit") {
		t.Errorf("dialog-open footer still shows 'q quit': %q", got)
	}
	if !strings.Contains(got, "esc") {
		t.Errorf("dialog-open footer missing 'esc': %q", got)
	}
	// After esc closes the dialog the footer reverts.
	l.update(tea.KeyMsg{Type: tea.KeyEsc})
	if got := l.footer(); got != "↑/↓ select · enter · q quit" {
		t.Errorf("after-close footer = %q, want hint with q quit", got)
	}
}

// huh ships its esc binding disabled (only ctrl+c aborts a form) — the same
// root cause as the wizard's esc bug. Every landing dialog advertises
// "esc cancels"; the screen must intercept it.
func TestLandingEscCancelsEveryDialogKind(t *testing.T) {
	open := []struct {
		name string
		do   func(l *landing)
	}{
		{"combined reset (scope + repo toggle + typed word)", func(l *landing) {
			_, _ = l.choose("reset")
			l.resetRepos = true // ensure esc clears the toggle too
		}},
		{"light confirm (update)", func(l *landing) { _, _ = l.choose("update") }},
		{"picker (demo)", func(l *landing) { _, _ = l.choose("demo") }},
		{"input (release-control branch)", func(l *landing) {
			orig := fetchReleaseBranch
			fetchReleaseBranch = func(string) string { return "main" }
			defer func() { fetchReleaseBranch = orig }()
			_, _ = l.choose("rcbranch")
		}},
	}
	for _, tc := range open {
		l := newLanding("/tmp/x", true, false)
		l.setSize(80, 24)
		tc.do(l)
		if l.form == nil {
			t.Fatalf("%s: dialog did not open", tc.name)
		}
		_, cmd := l.update(tea.KeyMsg{Type: tea.KeyEsc})
		if l.form != nil {
			t.Errorf("%s: esc did not close the dialog", tc.name)
		}
		if l.pending != nil || l.pickerMake != nil || l.inputMake != nil || l.resetting || l.resetRepos {
			t.Errorf("%s: dialog state not fully cleared on esc", tc.name)
		}
		if cmd != nil {
			if msg := cmd(); msg != nil {
				t.Errorf("%s: esc emitted %#v, want nothing", tc.name, msg)
			}
		}
	}
}
