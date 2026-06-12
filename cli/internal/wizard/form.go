package wizard

import (
	"errors"
	"fmt"
	"strings"

	"github.com/charmbracelet/huh"
)

// Form is the wizard's single definition (spec amendment 1): one constructor
// builds the field form and, after it completes, the confirm-summary form.
// Both hosts — the standalone CLI runner (RunForm) and the TUI's embedded
// wizard screen — consume this type and differ only in how they pump it.
type Form struct {
	// vals tracks the current user-visible values; it is the authoritative
	// source for Desired(). It is initialised from initial and refreshed by
	// syncFromHuh (called from BuildConfirm, which both hosts invoke once
	// Main completes) so that the select normalisation huh performs does not
	// clobber the caller-supplied seeds before the form has run.
	vals map[string]string
	// ptrs are the string pointers shared with the huh input/select fields.
	// huh may overwrite them during construction (select normalisation), so
	// they are NOT the source of truth until BuildConfirm syncs them back.
	ptrs map[string]*string
	// seed is the post-normalisation baseline captured at construction: the
	// values the form opened with, against which Dirty() reports edits. It is
	// distinct from vals (which BuildConfirm overwrites with the final entry)
	// and from skip's seed (seedSkip).
	seed      map[string]string
	seedSkip  bool
	skip      bool
	confirmed bool

	// Main is phase 1: the IdP selector and every field group.
	Main *huh.Form
	// Confirm is phase 2, built by BuildConfirm once Main completes (its
	// summary must reflect the final phase-1 values).
	Confirm *huh.Form
}

// NewForm seeds every field from initial (defaults or current .env merged
// with any flag-provided values) and skipAuth into the IdP selector.
func NewForm(initial map[string]string, skipAuth bool) *Form {
	f := &Form{
		vals: make(map[string]string, len(Fields)),
		ptrs: make(map[string]*string, len(Fields)),
		skip: skipAuth,
	}
	for _, fl := range Fields {
		v := initial[fl.Key]
		f.vals[fl.Key] = v
		huhV := v
		f.ptrs[fl.Key] = &huhV
	}

	idp := huh.NewSelect[bool]().
		Title("Identity provider").
		Description("PIC-SURE supports other identity providers, but this distribution wires the Auth0 path.").
		Options(
			huh.NewOption("Auth0 (recommended for evaluation)", false),
			huh.NewOption("Skip — I'll configure an identity provider manually", true),
		).
		Value(&f.skip)

	groups := []*huh.Group{
		huh.NewGroup(idp),
		huh.NewGroup(inputsFor(GroupAuth0, false, f.ptrs)...).
			WithHideFunc(func() bool { return f.skip }),
		huh.NewGroup(inputsFor(GroupAdmin, false, f.ptrs)...),
		huh.NewGroup(inputsFor(GroupPorts, false, f.ptrs)...),
		huh.NewGroup(inputsFor(GroupAuth, false, f.ptrs)...),
		huh.NewGroup(inputsFor(GroupDB, false, f.ptrs)...),
		// Remote connection details only when DB_MODE=remote.
		huh.NewGroup(inputsFor(GroupDB, true, f.ptrs)...).
			WithHideFunc(func() bool { return *f.ptrs["DB_MODE"] != "remote" }),
		// Release-control repo/branch is orthogonal to DB mode — always shown.
		huh.NewGroup(inputsFor(GroupReleaseControl, false, f.ptrs)...),
	}
	f.Main = huh.NewForm(groups...)
	// Capture the baseline AFTER construction: huh normalises select values
	// (an out-of-range seed snaps to a valid option) while building the
	// groups, so the seed must reflect what the user actually sees, or Dirty()
	// would report a phantom edit on the first open of a hand-normalised .env.
	f.seedSkip = f.skip
	f.seed = make(map[string]string, len(f.ptrs))
	for k, p := range f.ptrs {
		f.seed[k] = *p
	}
	return f
}

// Dirty reports whether any field (or the IdP selector) differs from the
// values the form opened with. It reads the live huh pointers, so it is valid
// at any point during phase 1 — used by the embedded host to gate an
// esc-discards-everything confirm.
func (f *Form) Dirty() bool {
	if f.skip != f.seedSkip {
		return true
	}
	for k, p := range f.ptrs {
		if *p != f.seed[k] {
			return true
		}
	}
	return false
}

// syncFromHuh copies the huh-owned pointer values into vals so that
// Desired() and the confirm summary reflect what the user entered.
func (f *Form) syncFromHuh() {
	for k, p := range f.ptrs {
		f.vals[k] = *p
	}
}

// BuildConfirm constructs phase 2: a confirm whose description summarizes
// the final phase-1 values. Call only after Main completes. Both hosts
// (the CLI's RunForm and the TUI's embedded screen) call BuildConfirm once
// Main completes, so this is where huh's bound values become the
// authoritative ones — the embedded host never calls Main.Run() and relies
// on this sync to observe edits.
func (f *Form) BuildConfirm() *huh.Form {
	f.syncFromHuh()
	// Build a snapshot of vals as pointers for summary (summary takes
	// map[string]*string for consistency with inputsFor).
	snap := make(map[string]*string, len(f.vals))
	for k := range f.vals {
		v := f.vals[k]
		snap[k] = &v
	}
	confirm := huh.NewConfirm().
		Title("Write these values to .env and run init.sh?").
		Description(summary(snap, f.skip)).
		Value(&f.confirmed)
	f.Confirm = huh.NewForm(huh.NewGroup(confirm))
	return f.Confirm
}

// Desired snapshots the current field values from vals (the authoritative
// source, not the huh-internal pointers which may have been normalised).
func (f *Form) Desired() map[string]string {
	out := make(map[string]string, len(f.vals))
	for k, v := range f.vals {
		out[k] = v
	}
	return out
}

// SkipAuth reports the IdP selector's current choice.
func (f *Form) SkipAuth() bool { return f.skip }

// Confirmed reports whether phase 2 was answered affirmatively.
func (f *Form) Confirmed() bool { return f.confirmed }

// RunForm runs the interactive wizard in the calling terminal (the
// standalone CLI host). initial seeds every field; skipAuth seeds the IdP
// selector. Returns the desired values, the final skip-auth choice, and
// whether the user confirmed writing them. A user abort (ctrl-c / esc)
// returns confirmed=false with no error.
func RunForm(initial map[string]string, skipAuth bool) (map[string]string, bool, bool, error) {
	f := NewForm(initial, skipAuth)
	if err := f.Main.Run(); err != nil {
		if errors.Is(err, huh.ErrUserAborted) {
			return nil, f.SkipAuth(), false, nil
		}
		return nil, f.SkipAuth(), false, err
	}
	if err := f.BuildConfirm().Run(); err != nil {
		if errors.Is(err, huh.ErrUserAborted) {
			return nil, f.SkipAuth(), false, nil
		}
		return nil, f.SkipAuth(), false, err
	}
	return f.Desired(), f.SkipAuth(), f.Confirmed(), nil
}

// inputsFor builds the huh fields for one group, split by the RemoteOnly
// marker so remote connection details can live in their own hideable group.
func inputsFor(group string, remoteOnly bool, vals map[string]*string) []huh.Field {
	var fields []huh.Field
	for _, f := range Fields {
		if f.Group != group || f.RemoteOnly != remoteOnly {
			continue
		}
		fields = append(fields, inputFor(f, vals))
	}
	return fields
}

func inputFor(f Field, vals map[string]*string) huh.Field {
	if len(f.Options) > 0 {
		opts := make([]huh.Option[string], len(f.Options))
		for i, o := range f.Options {
			opts[i] = huh.NewOption(o, o)
		}
		return huh.NewSelect[string]().
			Title(f.Title).
			Description(f.Help).
			Options(opts...).
			Value(vals[f.Key])
	}

	in := huh.NewInput().
		Title(f.Title).
		Description(f.Help).
		Value(vals[f.Key])
	if f.Secret {
		in = in.EchoMode(huh.EchoModePassword)
	}
	if f.Validate != nil {
		field := f
		in = in.Validate(func(s string) error {
			all := make(map[string]string, len(vals))
			for k, p := range vals {
				all[k] = *p
			}
			all[field.Key] = s
			return field.Validate(s, all)
		})
	}
	return in
}

func summary(vals map[string]*string, skip bool) string {
	var b strings.Builder
	if skip {
		b.WriteString("Identity provider: configured manually (Auth0 skipped)\n")
	}
	dbMode := *vals["DB_MODE"]
	for _, f := range Fields {
		if f.Auth0Required && skip {
			continue
		}
		if f.RemoteOnly && dbMode != "remote" {
			continue
		}
		v := *vals[f.Key]
		if f.Secret && v != "" {
			v = "********"
		}
		if v == "" {
			v = "(empty)"
		}
		fmt.Fprintf(&b, "%s: %s\n", f.Title, v)
	}
	return strings.TrimRight(b.String(), "\n")
}
