package tui

import "testing"

func TestAnimationsEnabled(t *testing.T) {
	env := func(vals map[string]string) func(string) string {
		return func(k string) string { return vals[k] }
	}
	tests := []struct {
		name   string
		noAnim bool
		vals   map[string]string
		want   bool
	}{
		{"default on", false, map[string]string{}, true},
		{"flag disables", true, map[string]string{}, false},
		{"env 1 disables", false, map[string]string{"PIC_SURE_NO_ANIMATIONS": "1"}, false},
		{"env true disables", false, map[string]string{"PIC_SURE_NO_ANIMATIONS": "true"}, false},
		{"ssh auto-disables", false, map[string]string{"SSH_CONNECTION": "10.0.0.1 22 10.0.0.2 22"}, false},
		{"env 0 overrides ssh (explicit opt-in)", false, map[string]string{"SSH_CONNECTION": "x", "PIC_SURE_NO_ANIMATIONS": "0"}, true},
		{"flag beats env opt-in", true, map[string]string{"PIC_SURE_NO_ANIMATIONS": "0"}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := AnimationsEnabled(tt.noAnim, env(tt.vals)); got != tt.want {
				t.Errorf("AnimationsEnabled = %v, want %v", got, tt.want)
			}
		})
	}
}
