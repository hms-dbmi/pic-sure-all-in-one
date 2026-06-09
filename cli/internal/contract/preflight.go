package contract

import (
	"encoding/json"
	"fmt"
)

// Preflight mirrors `preflight.sh --json` (schema_version 1).
type Preflight struct {
	SchemaVersion  int     `json:"schema_version"`
	Command        string  `json:"command"`
	NetworkChecked bool    `json:"network_checked"`
	Passed         bool    `json:"passed"`
	Checks         []Check `json:"checks"`
}

// Check statuses. Names are a stable catalog documented in
// docs/cli-contract.md; messages are human text and not stable.
const (
	CheckOK   = "ok"
	CheckWarn = "warn"
	CheckFail = "fail"
)

type Check struct {
	Name    string `json:"name"`
	Status  string `json:"status"` // ok | warn | fail
	Message string `json:"message"`
}

// ParsePreflight decodes `preflight.sh --json` output. Unknown fields are
// ignored; unknown check names are fine (additive catalog).
func ParsePreflight(data []byte) (*Preflight, error) {
	var p Preflight
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("parsing preflight JSON: %w", err)
	}
	if err := checkHeader(p.SchemaVersion, p.Command, "preflight"); err != nil {
		return nil, err
	}
	return &p, nil
}
