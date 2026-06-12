package tui

import (
	"errors"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/dashboard"
)

func testApp(start Screen) *app {
	a := newApp(Options{Root: "/tmp/x", Start: start, Animations: false})
	a.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	return a
}

func TestAppStartsOnRequestedScreen(t *testing.T) {
	if a := testApp(ScreenLanding); a.screen != ScreenLanding {
		t.Errorf("start screen = %v, want landing", a.screen)
	}
	a := testApp(ScreenDashboard)
	if a.screen != ScreenDashboard || a.dash == nil {
		t.Error("ScreenDashboard start did not construct the dashboard")
	}
}

func TestAppNavigationCycle(t *testing.T) {
	orig := startRunner
	startRunner = func(string, actions.Action, int, int) (runnerHandle, error) {
		return &fakeRunner{}, nil
	}
	t.Cleanup(func() { startRunner = orig })

	a := testApp(ScreenLanding)

	a.Update(openDashboardMsg{})
	if a.screen != ScreenDashboard || a.dash == nil {
		t.Fatal("openDashboardMsg did not open the dashboard")
	}

	a.Update(dashboard.BackMsg{})
	if a.screen != ScreenLanding || a.dash != nil {
		t.Fatal("BackMsg did not return to the landing / drop the dashboard")
	}

	a.Update(runActionMsg{act: actions.Preflight()})
	if a.screen != ScreenActivity || a.activity == nil {
		t.Fatal("runActionMsg did not open the activity screen")
	}

	a.Update(activityClosedMsg{openDashboard: true})
	if a.screen != ScreenDashboard {
		t.Fatal("activityClosedMsg{openDashboard} did not open the dashboard")
	}
	if a.activity != nil {
		t.Fatal("activity not dropped after close")
	}
}

func TestAppDropsStarfieldTicksOffLanding(t *testing.T) {
	a := testApp(ScreenLanding)
	a.Update(openDashboardMsg{})
	if _, cmd := a.Update(starTickMsg{seq: 1}); cmd != nil {
		t.Error("starfield tick rescheduled while off the landing screen")
	}
}

func TestWizardFlowResultMessages(t *testing.T) {
	t.Run("cancel shows neutral result", func(t *testing.T) {
		a := testApp(ScreenLanding)
		a.screen = ScreenWizard
		a.Update(wizardClosedMsg{aborted: true})
		if a.screen != ScreenLanding || !strings.Contains(a.landing.result, "cancelled") {
			t.Fatalf("screen=%v result=%q, want landing with cancelled message", a.screen, a.landing.result)
		}
	})
	t.Run("write failure returns to landing with error", func(t *testing.T) {
		a := testApp(ScreenLanding)
		a.screen = ScreenWizard
		a.Update(wizardWritesDoneMsg{err: errors.New("scripts/env-set.sh ADMIN_EMAIL exited 2")})
		if a.screen != ScreenLanding || !strings.Contains(a.landing.result, "failed") {
			t.Fatalf("screen=%v result=%q, want landing with failure", a.screen, a.landing.result)
		}
	})
	t.Run("write success launches init.sh in the activity screen", func(t *testing.T) {
		orig := startRunner
		startRunner = func(string, actions.Action, int, int) (runnerHandle, error) {
			return &fakeRunner{}, nil
		}
		t.Cleanup(func() { startRunner = orig })

		a := testApp(ScreenLanding)
		a.screen = ScreenWizard
		a.Update(wizardWritesDoneMsg{})
		if a.screen != ScreenActivity || a.activity == nil {
			t.Fatal("successful writes must open the activity screen")
		}
		if a.activity.act.Script != "init.sh" {
			t.Errorf("activity script = %q, want init.sh", a.activity.act.Script)
		}
	})
}

func TestAppLoadDataNavigation(t *testing.T) {
	a := testApp(ScreenLanding)

	// openLoadDataMsg constructs and routes to the guided load screen.
	a.Update(openLoadDataMsg{})
	if a.screen != ScreenLoadData || a.load == nil {
		t.Fatalf("openLoadDataMsg did not open the load screen (screen=%v load=%v)", a.screen, a.load != nil)
	}

	// A cancel closes back to the landing with the neutral result message.
	a.Update(loadDataClosedMsg{aborted: true})
	if a.screen != ScreenLanding || a.load != nil {
		t.Fatal("loadDataClosedMsg did not return to the landing / drop the load screen")
	}
	if !strings.Contains(a.landing.result, "cancelled") {
		t.Errorf("cancel result = %q, want a cancelled message", a.landing.result)
	}
}

func TestAppLoadDataDispatchOpensActivity(t *testing.T) {
	orig := startRunner
	startRunner = func(string, actions.Action, int, int) (runnerHandle, error) {
		return &fakeRunner{}, nil
	}
	t.Cleanup(func() { startRunner = orig })

	a := testApp(ScreenLanding)
	a.Update(openLoadDataMsg{})
	if a.load == nil {
		t.Fatal("load screen not open")
	}
	// The load screen emits a runActionMsg to launch the load; the app routes it
	// to the activity screen and drops the (now-closed) load screen.
	a.Update(runActionMsg{act: actions.LoadPhenotype(actions.PhenotypeOpts{File: "pheno.csv"})})
	if a.screen != ScreenActivity || a.activity == nil {
		t.Fatal("runActionMsg from the load screen did not open the activity screen")
	}
	if a.load != nil {
		t.Error("load screen not dropped after dispatch")
	}
	if a.activity.act.Script != "etl.sh" {
		t.Errorf("activity script = %q, want etl.sh", a.activity.act.Script)
	}
}

func TestOpenWizardNavigatesOrReportsError(t *testing.T) {
	// testApp's root (/tmp/x) has no .env.example → constructor error path.
	a := testApp(ScreenLanding)
	a.Update(openWizardMsg{})
	if a.screen != ScreenLanding || !strings.Contains(a.landing.result, "failed") {
		t.Fatalf("unreadable seed file must stay on landing with an error, got screen=%v result=%q", a.screen, a.landing.result)
	}

	// With a real seed file the wizard screen opens.
	root := wizardRoot(t, false)
	a = newApp(Options{Root: root})
	a.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	a.Update(openWizardMsg{})
	if a.screen != ScreenWizard || a.wizard == nil {
		t.Fatal("openWizardMsg did not open the wizard screen")
	}
}
