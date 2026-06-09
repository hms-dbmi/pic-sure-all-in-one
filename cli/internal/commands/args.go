package commands

import (
	"fmt"
	"slices"
	"strings"
)

// GlobalOptions are the binary's own flags, consumed wherever they appear on
// the command line (subcommands disable Cobra flag parsing so that script
// flags pass through verbatim; these names are reserved).
type GlobalOptions struct {
	Root         string // --root: checkout root override
	Yes          bool   // --yes / --non-interactive: never prompt
	NoAnimations bool   // --no-animations: static TUI (no starfield motion / logo shine)
}

// ScanGlobalArgs extracts the global flags from args and returns the
// remaining args untouched and in order. `--root VALUE` and `--root=VALUE`
// are both supported.
func ScanGlobalArgs(args []string) ([]string, GlobalOptions, error) {
	var opts GlobalOptions
	cleaned := make([]string, 0, len(args))

	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--":
			// Passthrough barrier: everything after a literal -- reaches the
			// script byte-verbatim, even the reserved global names (so e.g.
			// `pic-sure etl -- --root x` hands --root to etl.sh). The barrier
			// itself is consumed. Place it after the subcommand name.
			cleaned = append(cleaned, args[i+1:]...)
			return cleaned, opts, nil
		case arg == "--root":
			if i+1 >= len(args) {
				return nil, opts, fmt.Errorf("--root requires a directory argument")
			}
			i++
			opts.Root = args[i]
		case strings.HasPrefix(arg, "--root="):
			opts.Root = strings.TrimPrefix(arg, "--root=")
			if opts.Root == "" {
				return nil, opts, fmt.Errorf("--root requires a directory argument")
			}
		case arg == "--yes" || arg == "--non-interactive":
			opts.Yes = true
		case arg == "--no-animations":
			opts.NoAnimations = true
		default:
			cleaned = append(cleaned, arg)
		}
	}
	return cleaned, opts, nil
}

// ScriptCommand maps one subcommand to its backing script.
type ScriptCommand struct {
	Name        string
	Script      string   // path relative to the checkout root
	Prepend     []string // arguments inserted before the user's (compose verbs)
	SupportsYes bool     // script accepts --yes; global --yes is translated to it
	Prompts     bool     // script prompts on stdin without --yes (TTY refusal applies)
	Short       string
	FlagsHelp   string // hand-maintained surfaced flags for --help
}

// BuildScriptArgs computes the argv passed to the script. The user's args
// arrive already cleaned of global flags and are forwarded byte-verbatim;
// the only additions are the Prepend verbs and a translated --yes for
// scripts that support it.
func BuildScriptArgs(sc ScriptCommand, args []string, opts GlobalOptions, interactive bool) ([]string, error) {
	argv := make([]string, 0, len(sc.Prepend)+len(args)+1)
	argv = append(argv, sc.Prepend...)
	argv = append(argv, args...)

	if sc.SupportsYes && opts.Yes && !slices.Contains(argv, "--yes") {
		argv = append(argv, "--yes")
	}

	if sc.Prompts && !interactive && !slices.Contains(argv, "--yes") {
		return nil, fmt.Errorf("%s asks for confirmation on stdin, which is not a terminal; pass --yes to proceed non-interactively", sc.Name)
	}

	return argv, nil
}
