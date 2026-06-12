// Package wizard implements the guided `pic-sure init` setup: a data-driven
// field table derived from .env.example, rendered as a huh form (TTY) or
// satisfied by flags (non-interactive). All resulting .env writes go through
// scripts/env-set.sh — this package never touches .env itself.
package wizard

import (
	"fmt"
	"net/mail"
	"strconv"
	"strings"
)

// Group identifiers; the form renders one huh group per Group value, and an
// IdP selector can later be added by introducing a new group without
// restructuring (fields stay data-driven).
const (
	GroupAuth0 = "auth0"
	GroupAdmin = "admin"
	GroupPorts = "ports"
	GroupAuth  = "authmode"
	GroupDB    = "db"
)

// Field is one wizard entry mapping a .env key to a CLI flag.
type Field struct {
	Key    string // .env key (drift-guarded against .env.example)
	Flag   string // CLI flag, e.g. --auth0-client-id
	Group  string
	Title  string
	Help   string
	Secret bool // masked input

	// Requiredness is explicit per condition — never inferred from other
	// properties like the presence of a validator:
	//   Required           — always required when creating a new .env.
	//   Auth0Required      — required unless --skip-auth (PIC-SURE supports
	//                        other IdPs; this distro only wires the Auth0
	//                        path, so skipping is a deliberate alt-IdP setup).
	//   RequiredWhenRemote — required iff DB_MODE=remote.
	Required           bool
	Auth0Required      bool
	RequiredWhenRemote bool

	// RemoteOnly fields are only shown/asked when DB_MODE=remote.
	RemoteOnly bool

	Options  []string // non-empty → select input
	Validate func(value string, all map[string]string) error
}

// Fields is the wizard's field table, in form order. Defaults come from
// .env.example at runtime (the file is the source of truth; nothing is
// duplicated here except identity and UX text).
var Fields = []Field{
	{
		Key:           "AUTH0_CLIENT_ID",
		Flag:          "--auth0-client-id",
		Group:         GroupAuth0,
		Title:         "Auth0 client ID",
		Help:          "Evaluation credentials: avillachlabsupport.hms.harvard.edu → \"PIC-SURE All-in-one evaluation client credentials\"",
		Auth0Required: true,
		Validate:      nonEmpty("Auth0 client ID"),
	},
	{
		Key:           "AUTH0_CLIENT_SECRET",
		Flag:          "--auth0-client-secret",
		Group:         GroupAuth0,
		Title:         "Auth0 client secret",
		Help:          "Paired with the client ID",
		Secret:        true,
		Auth0Required: true,
		Validate:      nonEmpty("Auth0 client secret"),
	},
	{
		Key:   "AUTH0_TENANT",
		Flag:  "--auth0-tenant",
		Group: GroupAuth0,
		Title: "Auth0 tenant",
		Help:  "Leave the default unless you run your own tenant",
	},
	{
		Key:      "ADMIN_EMAIL",
		Flag:     "--admin-email",
		Group:    GroupAdmin,
		Title:    "Admin email",
		Help:     "Initial admin user (must be a Google account when using the Auth0 path)",
		Required: true,
		Validate: validEmail,
	},
	{
		Key:      "HTTP_PORT",
		Flag:     "--http-port",
		Group:    GroupPorts,
		Title:    "HTTP port",
		Help:     "Host port for the frontend; change if 80 is already in use",
		Validate: validPort,
	},
	{
		Key:      "HTTPS_PORT",
		Flag:     "--https-port",
		Group:    GroupPorts,
		Title:    "HTTPS port",
		Help:     "Host port for the HTTPS reverse proxy; must differ from the HTTP port",
		Validate: validHTTPSPort,
	},
	{
		Key:     "AUTH_MODE",
		Flag:    "--auth-mode",
		Group:   GroupAuth,
		Title:   "Auth mode",
		Help:    "open — Discover page without login, no export/API · explore — query builder without login, export prompts login · required — no access without login",
		Options: []string{"required", "open", "explore"},
	},
	{
		Key:     "DB_MODE",
		Flag:    "--db-mode",
		Group:   GroupDB,
		Title:   "Database mode",
		Help:    "local — bundled MySQL container · remote — external MySQL/RDS",
		Options: []string{"local", "remote"},
	},
	{
		Key:                "DB_HOST",
		Flag:               "--db-host",
		Group:              GroupDB,
		Title:              "Remote DB host",
		Help:               "Hostname or IP of the external MySQL (e.g. an RDS endpoint)",
		RemoteOnly:         true,
		RequiredWhenRemote: true,
		Validate:           nonEmpty("DB host"),
	},
	{
		Key:                "DB_PORT",
		Flag:               "--db-port",
		Group:              GroupDB,
		Title:              "Remote DB port",
		RemoteOnly:         true,
		RequiredWhenRemote: true,
		Validate:           validPort,
	},
	{
		Key:        "DB_ROOT_USER",
		Flag:       "--db-root-user",
		Group:      GroupDB,
		Title:      "Remote DB admin user",
		RemoteOnly: true,
	},
	{
		Key:                "DB_ROOT_PASSWORD",
		Flag:               "--db-root-password",
		Group:              GroupDB,
		Title:              "Remote DB admin password",
		Secret:             true,
		RemoteOnly:         true,
		RequiredWhenRemote: true,
		Validate:           nonEmpty("DB admin password"),
	},
}

// FieldByFlag returns the field for a CLI flag name (without value).
func FieldByFlag(flag string) (Field, bool) {
	for _, f := range Fields {
		if f.Flag == flag {
			return f, true
		}
	}
	return Field{}, false
}

// IsSecretKey reports whether a .env key holds a secret (masked in the
// wizard; written via env-set.sh --stdin so it never appears in argv).
func IsSecretKey(key string) bool {
	for _, f := range Fields {
		if f.Key == key {
			return f.Secret
		}
	}
	return false
}

// MissingRequired lists the flags that still need values for a
// non-interactive run, given collected values (flag-provided merged over
// defaults), whether Auth0 is being skipped, and the effective DB mode.
func MissingRequired(values map[string]string, skipAuth bool) []string {
	dbMode := values["DB_MODE"]
	var missing []string
	for _, f := range Fields {
		if f.RemoteOnly && dbMode != "remote" {
			continue
		}
		required := f.Required || (f.Auth0Required && !skipAuth) || (f.RequiredWhenRemote && dbMode == "remote")
		if required && strings.TrimSpace(values[f.Key]) == "" {
			missing = append(missing, f.Flag)
		}
	}
	return missing
}

// ValidateProvided runs field validation for exactly the provided keys, with
// the merged (current + provided) map as cross-field context. Used when
// field flags update an existing .env: only the user's inputs are judged —
// pre-existing untouched values are never re-validated, so a legacy .env
// cannot block an unrelated update.
func ValidateProvided(provided, all map[string]string) error {
	for _, f := range Fields {
		if f.Validate == nil {
			continue
		}
		if _, ok := provided[f.Key]; !ok {
			continue
		}
		if err := f.Validate(all[f.Key], all); err != nil {
			return fmt.Errorf("%s: %w", f.Flag, err)
		}
	}
	return nil
}

// ValidateAll runs every applicable field validation against values.
func ValidateAll(values map[string]string, skipAuth bool) error {
	dbMode := values["DB_MODE"]
	for _, f := range Fields {
		if f.Validate == nil {
			continue
		}
		if f.RemoteOnly && dbMode != "remote" {
			continue
		}
		if f.Auth0Required && skipAuth {
			continue
		}
		if err := f.Validate(values[f.Key], values); err != nil {
			return fmt.Errorf("%s: %w", f.Flag, err)
		}
	}
	return nil
}

// ChangedKeys returns the field keys whose desired value differs from
// current, in table order. Only these are written (never rewrite unchanged
// or generated values).
func ChangedKeys(current, desired map[string]string) []string {
	var changed []string
	for _, f := range Fields {
		want, ok := desired[f.Key]
		if !ok {
			continue
		}
		if current[f.Key] != want {
			changed = append(changed, f.Key)
		}
	}
	return changed
}

func nonEmpty(label string) func(string, map[string]string) error {
	return func(v string, _ map[string]string) error {
		if strings.TrimSpace(v) == "" {
			return fmt.Errorf("%s must not be empty", label)
		}
		return nil
	}
}

func validEmail(v string, _ map[string]string) error {
	if strings.TrimSpace(v) == "" {
		return fmt.Errorf("admin email must not be empty")
	}
	if _, err := mail.ParseAddress(v); err != nil {
		return fmt.Errorf("%q is not a valid email address", v)
	}
	return nil
}

func validPort(v string, _ map[string]string) error {
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < 1 || n > 65535 {
		return fmt.Errorf("%q is not a valid port (1-65535)", v)
	}
	return nil
}

func validHTTPSPort(v string, all map[string]string) error {
	if err := validPort(v, all); err != nil {
		return err
	}
	if strings.TrimSpace(v) == strings.TrimSpace(all["HTTP_PORT"]) {
		return fmt.Errorf("HTTPS port must differ from HTTP port (%s)", all["HTTP_PORT"])
	}
	return nil
}
