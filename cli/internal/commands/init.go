package commands

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/wizard"
)

// InitArgs is the parsed form of `pic-sure init` arguments: wizard field
// values, the wizard control flags, and everything else (passed through to
// init.sh verbatim).
type InitArgs struct {
	FieldValues map[string]string // .env key → value from --auth0-client-id etc.
	Wizard      bool              // --wizard: run the wizard over an existing .env
	SkipAuth    bool              // --skip-auth: deliberate alt-IdP setup
	Passthrough []string          // init.sh flags (--force, --verbose, ...)
}

// ParseInitArgs splits args into wizard concerns and init.sh passthrough.
// Field flags accept both `--flag VALUE` and `--flag=VALUE`.
func ParseInitArgs(args []string) (InitArgs, error) {
	out := InitArgs{FieldValues: map[string]string{}}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--wizard":
			out.Wizard = true
			continue
		case "--skip-auth":
			out.SkipAuth = true
			continue
		}

		flag, inlineValue, hasInline := strings.Cut(arg, "=")
		if f, ok := wizard.FieldByFlag(flag); ok {
			if hasInline {
				out.FieldValues[f.Key] = inlineValue
				continue
			}
			if i+1 >= len(args) {
				return out, fmt.Errorf("%s requires a value", flag)
			}
			i++
			out.FieldValues[f.Key] = args[i]
			continue
		}

		out.Passthrough = append(out.Passthrough, arg)
	}
	return out, nil
}

func (a *app) newInitCommand() *cobra.Command {
	long := `Runs init.sh from the checkout root.

When .env does not exist, a guided setup collects the required configuration
first (interactively on a terminal, or from flags below); the values are
written through scripts/env-set.sh and then init.sh runs. When .env exists,
init.sh runs directly — pass --wizard to review/update the configuration
first (only changed values are written; generated values are never touched).

Setup flags (each maps to one .env key):`
	for _, f := range wizard.Fields {
		long += fmt.Sprintf("\n  %-24s %s", f.Flag+" VALUE", f.Key)
	}
	long += `
  --skip-auth              create .env without Auth0 credentials (deliberate
                           alternate-IdP setup; admin email is still required)
  --wizard                 run the guided setup even though .env exists

Common init.sh flags (passed through verbatim, like everything else):
  --force  --verbose  --log  --release-control-branch BRANCH`

	return &cobra.Command{
		Use:                "init",
		Short:              "Initialize and start the PIC-SURE stack (guided setup on first run)",
		Long:               long,
		DisableFlagParsing: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			for _, arg := range args {
				if arg == "-h" || arg == "--help" {
					return cmd.Help()
				}
			}
			return a.runInit(args)
		},
	}
}

func (a *app) runInit(args []string) error {
	parsed, err := ParseInitArgs(args)
	if err != nil {
		return err
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	root, err := a.findRoot(cwd, a.opts.Root)
	if err != nil {
		return err
	}

	envPath := filepath.Join(root, ".env")
	_, statErr := os.Stat(envPath)
	envExists := statErr == nil

	// The global --yes/--non-interactive promises "never prompt": it makes a
	// TTY session behave like a pipe for every wizard decision below.
	interactive := a.isInteractive() && !a.opts.Yes

	switch {
	case envExists && !parsed.Wizard:
		// Preserve historical behavior: .env exists → init.sh directly.
		// Explicit field flags are still honored (changed keys only), but
		// validated first — only the provided values are judged, so a
		// legacy .env cannot block an unrelated update.
		if len(parsed.FieldValues) > 0 {
			current, err := wizard.ReadEnvValues(envPath)
			if err != nil {
				return err
			}
			if err := wizard.ValidateProvided(parsed.FieldValues, merge(current, parsed.FieldValues)); err != nil {
				return err
			}
			if err := a.writeChanged(root, current, parsed.FieldValues); err != nil {
				return err
			}
		}

	case envExists && parsed.Wizard:
		if !interactive {
			return fmt.Errorf("--wizard needs an interactive terminal and cannot be combined with --yes/--non-interactive; pass the setup flags instead (see pic-sure init --help)")
		}
		current, err := wizard.ReadEnvValues(envPath)
		if err != nil {
			return err
		}
		initial := merge(current, parsed.FieldValues)
		desired, _, confirmed, err := wizard.RunForm(initial, parsed.SkipAuth)
		if err != nil {
			return err
		}
		if !confirmed {
			fmt.Fprintln(os.Stderr, "Aborted; nothing written.")
			a.exitCode = 0
			return nil
		}
		if err := a.writeChanged(root, current, desired); err != nil {
			return err
		}

	default: // .env missing → guided setup
		defaults, err := wizard.ReadEnvValues(filepath.Join(root, ".env.example"))
		if err != nil {
			return fmt.Errorf("reading .env.example: %w", err)
		}
		initial := merge(defaults, parsed.FieldValues)

		missing := wizard.MissingRequired(initial, parsed.SkipAuth)
		complete := len(missing) == 0

		var desired map[string]string
		switch {
		case complete:
			// All required values provided: skip the wizard entirely.
			if err := wizard.ValidateAll(initial, parsed.SkipAuth); err != nil {
				return err
			}
			desired = initial
		case !interactive:
			return fmt.Errorf(
				"no .env and the wizard cannot run (not a terminal, or --yes/--non-interactive given); missing required flags: %s (or pass --skip-auth to configure an identity provider manually)",
				strings.Join(missing, " "))
		default:
			var confirmed bool
			desired, _, confirmed, err = wizard.RunForm(initial, parsed.SkipAuth)
			if err != nil {
				return err
			}
			if !confirmed {
				fmt.Fprintln(os.Stderr, "Aborted; nothing written.")
				a.exitCode = 0
				return nil
			}
		}

		// env-set.sh creates .env from .env.example on its first call; only
		// values differing from the template are written.
		if err := a.writeChanged(root, defaults, desired); err != nil {
			return err
		}
		// An untouched template is still a valid starting point (e.g.
		// --skip-auth with defaults): make sure .env exists for init.sh.
		if _, err := os.Stat(envPath); err != nil {
			if code, err := a.runScript(root, scripts.EnvSet, []string{"DB_MODE", desired["DB_MODE"]}); err != nil || code != 0 {
				return fmt.Errorf("creating .env via scripts/env-set.sh failed (exit %d): %v", code, err)
			}
		}
	}

	code, err := a.runScript(root, scripts.Init, parsed.Passthrough)
	if err != nil {
		return fmt.Errorf("running init.sh: %w", err)
	}
	a.exitCode = code
	return nil
}

// writeChanged delegates to the wizard package's single write path with
// this app's runner seams.
func (a *app) writeChanged(root string, current, desired map[string]string) error {
	return wizard.WriteChanged(wizard.RunScript(a.runScript), wizard.RunScriptInput(a.runScriptInput), root, current, desired)
}

func merge(base, overlay map[string]string) map[string]string {
	out := make(map[string]string, len(base)+len(overlay))
	for k, v := range base {
		out[k] = v
	}
	for k, v := range overlay {
		out[k] = v
	}
	return out
}
