package contract

import "testing"

func TestStatusDiagnosticsAreAdditive(t *testing.T) {
	for _, raw := range []string{
		`{"schema_version":1,"command":"status"}`,
		`{"schema_version":1,"command":"status","data":{"checked":true,"ready":null},"http":{"checked":true,"csp_source":"unknown"}}`,
	} {
		s, err := ParseStatus([]byte(raw))
		if err != nil {
			t.Fatal(err)
		}
		if s.Data.Ready != nil || s.Env.IntrospectionConfigured != nil {
			t.Fatal("unknown diagnostics must remain unknown")
		}
	}
	s, err := ParseStatus([]byte(`{"schema_version":1,"command":"status","data":{"checked":true,"ready":false},"env":{"introspection_configured":false},"http":{"checked":true,"csp_source":"floor"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if s.Data.Ready == nil || *s.Data.Ready || s.Env.IntrospectionConfigured == nil || *s.Env.IntrospectionConfigured || s.HTTP.CSPSource != "floor" {
		t.Fatalf("lost diagnostics: %+v", s)
	}
}
