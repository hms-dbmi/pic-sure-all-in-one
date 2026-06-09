package wizard

import (
	"bufio"
	"os"
	"strings"
)

// ReadEnvValues extracts KEY=VALUE pairs for the wizard's field keys from an
// env file (.env for pre-fill, .env.example for defaults). Read-only: writes
// always go through scripts/env-set.sh.
//
// Supported syntax: plain or `export `-prefixed assignments, with optional
// single or double quotes around the value (env-set.sh writes single-quoted
// values when they contain special characters). Known limitation: inline
// trailing comments and multi-assignment lines are not understood — a value
// from such a line pre-fills the wizard verbatim. Worst case is a wrong
// form default, never a wrong write.
func ReadEnvValues(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()

	wanted := make(map[string]bool, len(Fields))
	for _, fld := range Fields {
		wanted[fld.Key] = true
	}

	values := make(map[string]string)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		key, value, ok := strings.Cut(line, "=")
		if !ok || !wanted[key] {
			continue
		}
		values[key] = unquote(value)
	}
	return values, scanner.Err()
}

func unquote(v string) string {
	if len(v) >= 2 {
		if (v[0] == '\'' && v[len(v)-1] == '\'') || (v[0] == '"' && v[len(v)-1] == '"') {
			inner := v[1 : len(v)-1]
			if v[0] == '\'' {
				// env-set.sh escapes embedded single quotes as '\''.
				inner = strings.ReplaceAll(inner, `'\''`, `'`)
			}
			return inner
		}
	}
	return v
}
