// Package contract holds the Go view of the script JSON contract
// (docs/cli-contract.md). It is the only package that knows the JSON
// shapes; everything else consumes these types.
package contract

import (
	"encoding/json"
	"fmt"
)

// SchemaVersion is the contract major version this binary understands.
const SchemaVersion = 1

// Status mirrors `status.sh --json` (schema_version 1).
type Status struct {
	SchemaVersion  int            `json:"schema_version"`
	Command        string         `json:"command"`
	Env            StatusEnv      `json:"env"`
	ReleaseControl ReleaseControl `json:"release_control"`
	Repos          []Repo         `json:"repos"`
	Docker         Docker         `json:"docker"`
	Services       []Service      `json:"services"`
	Database       Database       `json:"database"`
	Migrations     Migrations     `json:"migrations"`
}

type StatusEnv struct {
	FilePresent        bool    `json:"file_present"`
	FileValid          *bool   `json:"file_valid"`
	ComposeProjectName string  `json:"compose_project_name"`
	DBMode             string  `json:"db_mode"`
	DBHost             *string `json:"db_host"`
	DBPort             *string `json:"db_port"`
	AuthMode           string  `json:"auth_mode"`
	PicsureImageTag    string  `json:"picsure_image_tag"`
}

type ReleaseControl struct {
	Repo   string            `json:"repo"`
	Branch string            `json:"branch"`
	Commit *string           `json:"commit"`
	Refs   map[string]string `json:"refs"`
}

type Repo struct {
	Name    string  `json:"name"`
	Present bool    `json:"present"`
	Current *string `json:"current"`
	Target  string  `json:"target"`
	State   string  `json:"state"` // clean | dirty | missing
}

type Docker struct {
	CLIPresent         bool  `json:"cli_present"`
	ComposeAvailable   bool  `json:"compose_available"`
	DaemonReachable    bool  `json:"daemon_reachable"`
	ComposeConfigValid *bool `json:"compose_config_valid"`
}

type Service struct {
	Name     string  `json:"name"`
	State    *string `json:"state"`
	Health   *string `json:"health"`
	ExitCode *int    `json:"exit_code"`
}

type Database struct {
	Mode    string  `json:"mode"`
	Service *string `json:"service"`
	Host    *string `json:"host"`
	Port    *string `json:"port"`
}

type Migrations struct {
	Checked bool   `json:"checked"`
	Ready   *bool  `json:"ready"`
	Message string `json:"message"`
}

// ParseStatus decodes `status.sh --json` output. Unknown fields are ignored
// (the contract allows additive changes); a schema_version other than
// SchemaVersion is an error.
func ParseStatus(data []byte) (*Status, error) {
	var s Status
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("parsing status JSON: %w", err)
	}
	if err := checkHeader(s.SchemaVersion, s.Command, "status"); err != nil {
		return nil, err
	}
	return &s, nil
}

func checkHeader(version int, command, want string) error {
	if version != SchemaVersion {
		return fmt.Errorf("unsupported schema_version %d (this binary speaks %d); upgrade pic-sure or the scripts so they match", version, SchemaVersion)
	}
	if command != want {
		return fmt.Errorf("unexpected command %q in JSON document (want %q)", command, want)
	}
	return nil
}
