// Package dialog holds huh dialog builders shared by the TUI surfaces (the
// landing screen in internal/tui and the dashboard in internal/dashboard).
// It is its own package because both callers need the form construction but
// neither may import the other (internal/tui already imports
// internal/dashboard, so the dashboard cannot reach back into tui), and the
// actions package may not depend on huh. The builder returns the *huh.Form
// unsized: each screen feeds it the synthetic WindowSizeMsg through its own
// sizeForm, since the two render the form into differently sized regions.
package dialog

import (
	"fmt"

	"github.com/charmbracelet/huh"
)

// ResetForm builds the combined reset dialog: ONE screen carrying the scope
// choice (keep the database vs. full wipe), the reset-sibling-repos toggle,
// and the typed-word confirm — so the two reset variants share a single
// dialog instead of two menu items. The caller owns the bound state: scope is
// set to "keep" or "all", repos toggles the --repos flag, and confirmText must
// equal word to authorize dispatch. The form is returned UNSIZED; the caller
// sizes it (landing.sizeForm / dashboard.sizeForm) to the region it renders in.
//
// Both selects bind Value BEFORE Options (huh gotcha: the option viewport's
// scroll offset is computed from the accessor's current value when Options()
// runs); the caller must preset *scope to a real option so the cursor is not
// pinned to an empty row.
func ResetForm(scope *string, repos *bool, confirmText *string, word string) *huh.Form {
	scopeField := huh.NewSelect[string]().
		Title("⚠ Reset — this destroys data").
		Description("Stops all containers and removes generated state so you can re-init:\n"+
			"  • .env (backed up first), certs/, .data/, generated config, deployed WARs\n"+
			".env.example is kept; sibling repos are kept unless toggled below.\n"+
			"Choose how much to wipe:").
		Value(scope).
		Options(
			huh.NewOption("Keep the database — picsure-db data preserved; re-init reuses it", "keep"),
			huh.NewOption("Full wipe — also drop the DB volume, PIC-SURE images, and the Maven cache", "all"),
		)

	reposField := huh.NewConfirm().
		Title("Also reset sibling repos to release refs").
		Description("Discards uncommitted repo changes; keeps local branches & history.").
		Affirmative("Reset repos too").
		Negative("Leave repos alone").
		Value(repos)

	confirmField := huh.NewInput().
		Title(fmt.Sprintf("Type %q to confirm", word)).
		Description("(esc cancels)").
		Value(confirmText).
		Validate(func(s string) error {
			if s != word {
				return fmt.Errorf("type %q exactly to confirm", word)
			}
			return nil
		})

	return huh.NewForm(huh.NewGroup(scopeField, reposField, confirmField)).WithShowHelp(true)
}
