package dashboard

import (
	"errors"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/actions"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/contract"
)

func TestDiagnosticSummary(t *testing.T) {
	for _, tc := range []struct {
		name string
		data contract.Data
		csp  string
		want string
	}{
		{"old script", contract.Data{}, "", "data readiness unchecked"},
		{"unknown", contract.Data{Checked: true}, "unknown", "data readiness unknown"},
		{"locked", contract.Data{Checked: true, Ready: boolPtr(false)}, "frontend", "data not ready"},
		{"floor", contract.Data{Checked: true, Ready: boolPtr(true)}, "floor", "CSP floor on HTML"},
		{"duplicate", contract.Data{Checked: true, Ready: boolPtr(true)}, "both", "multiple CSP policies"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := testModel(t)
			m.status = &contract.Status{Data: tc.data, HTTP: contract.HTTP{Checked: true, CSPSource: tc.csp}}
			if body := m.summaryBody(); !strings.Contains(body, tc.want) {
				t.Fatalf("missing %q in %s", tc.want, body)
			}
		})
	}
}

func TestHealthKeyHonorsPollLatch(t *testing.T) {
	m := testModel(t)
	m.pollingStatus = false
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'h'}})
	if cmd == nil || !m.pollingStatus {
		t.Fatal("health key did not start poll")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'h'}})
	if cmd != nil {
		t.Fatal("health key started concurrent poll")
	}
}

func TestDeepDiagnosticsSurviveCheapPoll(t *testing.T) {
	m := testModel(t)
	checked := time.Date(2026, 9, 21, 12, 34, 56, 0, time.Local)
	deep := &contract.Status{Data: contract.Data{Checked: true, Ready: boolPtr(false)}, HTTP: contract.HTTP{Checked: true, CSPSource: "floor"}}
	_, _ = m.Update(statusMsg{status: deep, deep: true, startedAt: checked, checkedAt: checked})
	cheap := &contract.Status{Env: contract.StatusEnv{ComposeProjectName: "refreshed"}}
	_, _ = m.Update(statusMsg{status: cheap})
	if m.status.Data.Ready == nil || *m.status.Data.Ready || m.status.HTTP.CSPSource != "floor" {
		t.Fatal("cheap poll erased deep diagnostics")
	}
	if m.status.Env.ComposeProjectName != "refreshed" {
		t.Fatal("cheap state did not refresh")
	}
	body := m.summaryBody()
	if !strings.Contains(body, "Health checked 2026-09-21 12:34:56") || !strings.Contains(body, "data not ready") {
		t.Fatalf("missing age or result: %s", body)
	}
}

func TestUnknownReadinessIsNeutral(t *testing.T) {
	for _, checked := range []bool{false, true} {
		m := testModel(t)
		m.status = &contract.Status{
			Env:    contract.StatusEnv{FilePresent: true, FileValid: boolPtr(true), IntrospectionConfigured: boolPtr(true)},
			Docker: contract.Docker{DaemonReachable: true, ComposeConfigValid: boolPtr(true)},
			Data:   contract.Data{Checked: checked},
		}
		body := m.summaryBody()
		if strings.Contains(body, "Warnings") || strings.Contains(body, "Blockers") || !strings.Contains(body, "data readiness") {
			t.Fatalf("unknown readiness must be neutral: %s", body)
		}
	}
}

func TestMutationsInvalidateDeepDiagnosticsIncludingInflight(t *testing.T) {
	orig := startPTY
	startPTY = func(string, actions.Action, int, int) (runnerHandle, error) { return &fakeRunner{}, nil }
	t.Cleanup(func() { startPTY = orig })
	m := testModel(t)
	checked := time.Now().Add(-time.Minute)
	deep := &contract.Status{Data: contract.Data{Checked: true, Ready: boolPtr(true)}}
	_, _ = m.Update(statusMsg{status: deep, deep: true, startedAt: checked, checkedAt: checked})
	_, _ = m.startAction(actions.Preflight())
	_, _ = m.Update(actions.DoneMsg{Code: 0})
	if m.deepCheckedAt.IsZero() {
		t.Fatal("read-only preflight invalidated diagnostic")
	}
	_, _ = m.startAction(actions.Restart("hpds"))
	if !m.deepCheckedAt.IsZero() || m.lastDeepStatus != nil || m.status.Data.Checked {
		t.Fatal("restart did not invalidate diagnostic")
	}
	stale := &contract.Status{Data: contract.Data{Checked: true, Ready: boolPtr(true)}}
	_, _ = m.Update(statusMsg{status: stale, deep: true, startedAt: checked, checkedAt: time.Now()})
	if m.lastDeepStatus != nil || m.status.Data.Checked {
		t.Fatal("stale in-flight poll restored readiness")
	}
	_, _ = m.Update(actions.DoneMsg{Code: 0})
	_, _ = m.Update(statusMsg{status: &contract.Status{}})
	if m.status.Data.Checked {
		t.Fatal("post-mutation cheap poll restored readiness")
	}
}

func TestFailedDeepCheckDoesNotRestoreEarlierSuccess(t *testing.T) {
	m := testModel(t)
	now := time.Now()
	_, _ = m.Update(statusMsg{status: &contract.Status{Data: contract.Data{Checked: true, Ready: boolPtr(true)}}, deep: true, startedAt: now, checkedAt: now})
	_, _ = m.Update(statusMsg{err: errors.New("timeout"), deep: true, startedAt: now, checkedAt: now})
	_, _ = m.Update(statusMsg{status: &contract.Status{}})
	if m.status.Data.Ready != nil || m.lastDeepStatus != nil {
		t.Fatal("failed deep check restored old success")
	}
}
