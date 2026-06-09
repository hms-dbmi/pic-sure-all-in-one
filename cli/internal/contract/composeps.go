package contract

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// ComposeService is one row of `scripts/compose.sh ps --format json`. Only
// the fields the dashboard needs are modeled; compose emits many more.
type ComposeService struct {
	Service  string `json:"Service"`
	State    string `json:"State"`
	Health   string `json:"Health"`
	ExitCode int    `json:"ExitCode"`
}

// ParseComposePS parses docker compose ps JSON output. Newer compose v2
// emits NDJSON (one object per line); older releases emit a single JSON
// array. Empty input means no services.
func ParseComposePS(data []byte) ([]ComposeService, error) {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 {
		return nil, nil
	}

	if trimmed[0] == '[' {
		var services []ComposeService
		if err := json.Unmarshal(trimmed, &services); err != nil {
			return nil, fmt.Errorf("parsing compose ps array: %w", err)
		}
		return services, nil
	}

	var services []ComposeService
	scanner := bufio.NewScanner(bytes.NewReader(trimmed))
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var s ComposeService
		if err := json.Unmarshal([]byte(line), &s); err != nil {
			return nil, fmt.Errorf("parsing compose ps line %q: %w", line, err)
		}
		services = append(services, s)
	}
	return services, scanner.Err()
}
