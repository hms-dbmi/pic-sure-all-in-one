// Package commands wires the Cobra command tree. Every subcommand is a thin
// dispatcher over a bash script (the scripts remain the single source of
// truth for all state mutations — see docs/cli-contract.md).
package commands

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/exec"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/project"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/tty"
	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/tui"
)

// BuildInfo carries the ldflags-injected version metadata.
type BuildInfo struct {
	Version string
	Commit  string
	Date    string
}

type app struct {
	info     BuildInfo
	opts     GlobalOptions
	exitCode int
	// Seams for tests.
	runScript      func(root, script string, args []string) (int, error)
	runScriptInput func(root, script string, args []string, input string) (int, error)
	findRoot       func(start, override string) (string, error)
	isInteractive  func() bool
	startTUI       func(o tui.Options) error
}

// Execute runs the CLI and returns the process exit code. Script exit codes
// propagate unchanged.
func Execute(info BuildInfo) int {
	cleaned, opts, err := ScanGlobalArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "pic-sure:", err)
		return 2
	}

	a := &app{
		info:           info,
		opts:           opts,
		runScript:      exec.Run,
		runScriptInput: exec.RunWithInput,
		findRoot:       project.FindRoot,
		isInteractive:  tty.IsInteractive,
		startTUI:       tui.Run,
	}

	root := a.rootCommand()
	root.SetArgs(cleaned)
	if err := root.Execute(); err != nil {
		// Cobra has already printed the error (SilenceErrors is unset).
		return 1
	}
	return a.exitCode
}

func (a *app) rootCommand() *cobra.Command {
	root := &cobra.Command{
		Use:   "pic-sure",
		Short: "Manage a PIC-SURE All-in-One deployment",
		Long: `pic-sure is a frontend for the PIC-SURE All-in-One deployment scripts.

Every operation runs the corresponding bash script from the checkout root;
the scripts remain fully usable on their own.

Global flags (accepted anywhere on the command line):
  --root DIR           checkout root (default: walk up from the working
                       directory looking for .env.example + docker-compose.yml)
  --yes, --non-interactive
                       never prompt; translated to the script's own --yes
                       where supported (reset, uninstall)
  --no-animations      static TUI (no starfield motion / logo shine)

These names are reserved; to hand one of them to a script literally, put a
-- after the subcommand: everything past it passes through byte-verbatim
(e.g. pic-sure etl -- --root /data).`,
		Version:      fmt.Sprintf("%s (commit %s, built %s)", a.info.Version, a.info.Commit, a.info.Date),
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			// Bare invocation on a terminal launches the landing;
			// otherwise print help (never start a TUI on a pipe).
			if a.isInteractive() {
				return a.runTUI(tui.ScreenLanding)
			}
			return cmd.Help()
		},
	}

	root.AddCommand(a.newInitCommand())
	root.AddCommand(a.newDashboardCommand())
	for _, sc := range scriptCommandTable {
		root.AddCommand(a.newScriptCommand(sc))
	}
	return root
}

func (a *app) newDashboardCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "dashboard",
		Short: "Open the TUI on the dashboard screen (bare `pic-sure` opens the landing menu)",
		Long: `Live service list, status summary, and log viewer, with keybound actions
that run the real scripts in an embedded terminal. Destructive actions
(reset, uninstall) require typing the action name to confirm.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			if !a.isInteractive() {
				return fmt.Errorf("the dashboard needs a terminal")
			}
			return a.runTUI(tui.ScreenDashboard)
		},
	}
}

func (a *app) runTUI(start tui.Screen) error {
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	root, err := a.findRoot(cwd, a.opts.Root)
	if err != nil {
		return err
	}
	return a.startTUI(tui.Options{
		Root:       root,
		Start:      start,
		Animations: tui.AnimationsEnabled(a.opts.NoAnimations, os.Getenv),
	})
}

func (a *app) newScriptCommand(sc ScriptCommand) *cobra.Command {
	use := sc.Name
	return &cobra.Command{
		Use:   use,
		Short: sc.Short,
		Long:  scriptCommandLong(sc),
		// Verbatim passthrough: scripts use both `--flag value` and
		// `--flag=value` plus positionals; Cobra must not touch them.
		DisableFlagParsing: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			for _, arg := range args {
				if arg == "-h" || arg == "--help" {
					return cmd.Help()
				}
			}

			argv, err := BuildScriptArgs(sc, args, a.opts, a.isInteractive())
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

			code, err := a.runScript(root, sc.Script, argv)
			if err != nil {
				return fmt.Errorf("running %s: %w", sc.Script, err)
			}
			a.exitCode = code
			return nil
		},
	}
}

func scriptCommandLong(sc ScriptCommand) string {
	long := fmt.Sprintf("Runs %s from the checkout root.\n", sc.Script)
	if len(sc.Prepend) > 0 {
		long = fmt.Sprintf("Runs `%s %s` from the checkout root.\n", sc.Script, sc.Prepend[0])
	}
	if sc.FlagsHelp != "" {
		long += fmt.Sprintf("\nCommon flags:\n  %s\n", sc.FlagsHelp)
	}
	long += fmt.Sprintf("\nAll arguments pass through to the script verbatim; see `%s --help`\nfor the authoritative list.", sc.Script)
	if sc.Prompts {
		long += "\n\nPrompts for confirmation; pass --yes when running non-interactively."
	}
	return long
}
