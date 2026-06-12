package commands

import (
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/tui"
)

func TestScanGlobalArgs(t *testing.T) {
	tests := []struct {
		name     string
		in       []string
		wantArgs []string
		wantOpts GlobalOptions
		wantErr  bool
	}{
		{
			name:     "no globals pass through untouched",
			in:       []string{"update", "--dry-run", "--offline"},
			wantArgs: []string{"update", "--dry-run", "--offline"},
		},
		{
			// The literal -- barrier is PRESERVED in the cleaned args (no
			// global-flag extraction past it). The subcommand layer strips the
			// first -- and forwards the rest byte-verbatim, so positional
			// information survives all the way to the help intercept (B12/B21).
			name:     "-- stops global scanning and is preserved; remainder passes verbatim",
			in:       []string{"etl", "--", "--root", "/x", "--yes"},
			wantArgs: []string{"etl", "--", "--root", "/x", "--yes"},
		},
		{
			name:     "globals before -- still apply; barrier preserved",
			in:       []string{"--root", "/r", "reset", "--", "--yes"},
			wantArgs: []string{"reset", "--", "--yes"},
			wantOpts: GlobalOptions{Root: "/r"},
		},
		{
			name:     "root with space value",
			in:       []string{"--root", "/some/dir", "status", "--json"},
			wantArgs: []string{"status", "--json"},
			wantOpts: GlobalOptions{Root: "/some/dir"},
		},
		{
			name:     "root with equals value after subcommand",
			in:       []string{"status", "--root=/some/dir", "--json"},
			wantArgs: []string{"status", "--json"},
			wantOpts: GlobalOptions{Root: "/some/dir"},
		},
		{
			name:     "yes stripped wherever it appears",
			in:       []string{"uninstall", "--yes", "--images"},
			wantArgs: []string{"uninstall", "--images"},
			wantOpts: GlobalOptions{Yes: true},
		},
		{
			name:     "no-animations stripped and sets NoAnimations",
			in:       []string{"--no-animations", "update", "--dry-run"},
			wantArgs: []string{"update", "--dry-run"},
			wantOpts: GlobalOptions{NoAnimations: true},
		},
		{
			name:     "non-interactive is an alias for yes",
			in:       []string{"--non-interactive", "reset", "--all"},
			wantArgs: []string{"reset", "--all"},
			wantOpts: GlobalOptions{Yes: true},
		},
		{
			name:     "equals-form script flags are preserved byte-verbatim",
			in:       []string{"release-control", "--branch=release/2.4", "--dry-run"},
			wantArgs: []string{"release-control", "--branch=release/2.4", "--dry-run"},
		},
		{
			name:     "etl subcommand positionals preserved in order",
			in:       []string{"etl", "load-csv", "--file", "/data/allConcepts.csv", "--heap", "4096"},
			wantArgs: []string{"etl", "load-csv", "--file", "/data/allConcepts.csv", "--heap", "4096"},
		},
		{
			name:    "root without value errors",
			in:      []string{"status", "--root"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, opts, err := ScanGlobalArgs(tt.in)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tt.wantArgs) {
				t.Errorf("args = %v, want %v", got, tt.wantArgs)
			}
			if opts != tt.wantOpts {
				t.Errorf("opts = %+v, want %+v", opts, tt.wantOpts)
			}
		})
	}
}

func TestSplitBarrier(t *testing.T) {
	tests := []struct {
		name        string
		in          []string
		wantPre     []string
		wantPost    []string
		wantBarrier bool
	}{
		{
			name:    "no barrier",
			in:      []string{"--help", "foo"},
			wantPre: []string{"--help", "foo"},
		},
		{
			name:        "barrier first",
			in:          []string{"--", "--help"},
			wantPre:     []string{},
			wantPost:    []string{"--help"},
			wantBarrier: true,
		},
		{
			name:        "barrier in the middle",
			in:          []string{"load-csv", "--", "--root", "/x"},
			wantPre:     []string{"load-csv"},
			wantPost:    []string{"--root", "/x"},
			wantBarrier: true,
		},
		{
			name:        "only the first -- is the barrier; later -- pass verbatim",
			in:          []string{"--", "--", "--help"},
			wantPre:     []string{},
			wantPost:    []string{"--", "--help"},
			wantBarrier: true,
		},
		{
			name:        "trailing barrier with nothing after it",
			in:          []string{"foo", "--"},
			wantPre:     []string{"foo"},
			wantPost:    []string{},
			wantBarrier: true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pre, post, hasBarrier := splitBarrier(tt.in)
			if hasBarrier != tt.wantBarrier {
				t.Errorf("hasBarrier = %v, want %v", hasBarrier, tt.wantBarrier)
			}
			if !reflect.DeepEqual(pre, tt.wantPre) {
				t.Errorf("pre = %v, want %v", pre, tt.wantPre)
			}
			if !reflect.DeepEqual(post, tt.wantPost) {
				t.Errorf("post = %v, want %v", post, tt.wantPost)
			}
		})
	}
}

func cmdByName(t *testing.T, name string) ScriptCommand {
	t.Helper()
	for _, sc := range scriptCommandTable {
		if sc.Name == name {
			return sc
		}
	}
	t.Fatalf("no command %q in table", name)
	return ScriptCommand{}
}

// endToEndArgv runs the full path a command line takes: global scan, then
// script argv construction. in excludes the subcommand name itself.
func endToEndArgv(t *testing.T, command string, in []string, interactive bool) ([]string, error) {
	t.Helper()
	cleaned, opts, err := ScanGlobalArgs(in)
	if err != nil {
		t.Fatal(err)
	}
	return BuildScriptArgs(cmdByName(t, command), cleaned, opts, interactive)
}

func TestBuildScriptArgs(t *testing.T) {
	t.Run("global yes translates to uninstall.sh --yes", func(t *testing.T) {
		argv, err := endToEndArgv(t, "uninstall", []string{"--yes"}, true)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"--yes"}; !reflect.DeepEqual(argv, want) {
			t.Errorf("argv = %v, want %v", argv, want)
		}
	})

	t.Run("global yes translates to reset.sh --yes with other flags preserved", func(t *testing.T) {
		argv, err := endToEndArgv(t, "reset", []string{"--all", "--yes"}, false)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"--all", "--yes"}; !reflect.DeepEqual(argv, want) {
			t.Errorf("argv = %v, want %v", argv, want)
		}
	})

	t.Run("yes is not duplicated", func(t *testing.T) {
		cleaned := []string{"--yes"} // user typed it; scan would strip, but guard the raw path too
		argv, err := BuildScriptArgs(cmdByName(t, "uninstall"), cleaned, GlobalOptions{Yes: true}, true)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"--yes"}; !reflect.DeepEqual(argv, want) {
			t.Errorf("argv = %v, want %v", argv, want)
		}
	})

	t.Run("yes is not appended to scripts without --yes support", func(t *testing.T) {
		argv, err := endToEndArgv(t, "update", []string{"--yes", "--dry-run"}, true)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"--dry-run"}; !reflect.DeepEqual(argv, want) {
			t.Errorf("argv = %v, want %v", argv, want)
		}
	})

	t.Run("reset refuses non-interactive without yes", func(t *testing.T) {
		_, err := endToEndArgv(t, "reset", []string{"--all"}, false)
		if err == nil {
			t.Fatal("expected refusal")
		}
		if !strings.Contains(err.Error(), "--yes") {
			t.Errorf("refusal must name --yes, got: %v", err)
		}
	})

	t.Run("reset interactive without yes passes through (script prompts)", func(t *testing.T) {
		argv, err := endToEndArgv(t, "reset", []string{"--all"}, true)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"--all"}; !reflect.DeepEqual(argv, want) {
			t.Errorf("argv = %v, want %v", argv, want)
		}
	})

	t.Run("uninstall without yes is allowed non-interactively (plan-only mode)", func(t *testing.T) {
		argv, err := endToEndArgv(t, "uninstall", nil, false)
		if err != nil {
			t.Fatal(err)
		}
		if len(argv) != 0 {
			t.Errorf("argv = %v, want empty", argv)
		}
	})

	t.Run("compose verbs are prepended", func(t *testing.T) {
		argv, err := endToEndArgv(t, "restart", []string{"wildfly", "psama"}, true)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"restart", "wildfly", "psama"}; !reflect.DeepEqual(argv, want) {
			t.Errorf("argv = %v, want %v", argv, want)
		}
	})

	t.Run("equals-form and positionals reach the script byte-verbatim", func(t *testing.T) {
		argv, err := endToEndArgv(t, "release-control", []string{"--branch=release/2.4", "--dry-run"}, true)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"--branch=release/2.4", "--dry-run"}; !reflect.DeepEqual(argv, want) {
			t.Errorf("argv = %v, want %v", argv, want)
		}
	})

	t.Run("etl args pass through verbatim", func(t *testing.T) {
		in := []string{"load-csv", "--file", "/data/all.csv", "--heap", "4096"}
		argv, err := endToEndArgv(t, "etl", in, true)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(argv, in) {
			t.Errorf("argv = %v, want %v", argv, in)
		}
	})
}

// scriptRunApp builds an app whose script runs are captured (not executed),
// then runs the full cobra path (ScanGlobalArgs → root.Execute → RunE). The
// argv slice it returns is nil when no script was invoked (e.g. the -h/--help
// intercept fired and printed Cobra help instead). osArgs excludes the binary
// name, exactly like os.Args[1:].
func scriptRunApp(t *testing.T, interactive bool) (*app, *string, *[]string) {
	t.Helper()
	var ranScript string
	var ranArgs []string
	ranArgs = nil
	a := &app{
		findRoot:      func(start, override string) (string, error) { return "/fake/root", nil },
		isInteractive: func() bool { return interactive },
		runScript: func(root, script string, args []string) (int, error) {
			ranScript = script
			ranArgs = args
			return 0, nil
		},
	}
	return a, &ranScript, &ranArgs
}

// runCLI threads osArgs through ScanGlobalArgs and the cobra tree, mirroring
// Execute() so the -h/--help intercept and barrier handling are exercised.
func runCLI(t *testing.T, a *app, osArgs []string) error {
	t.Helper()
	cleaned, opts, err := ScanGlobalArgs(osArgs)
	if err != nil {
		return err
	}
	a.opts = opts
	root := a.rootCommand()
	root.SetArgs(cleaned)
	root.SetOut(io.Discard)
	root.SetErr(io.Discard)
	return root.Execute()
}

func TestScriptHelpInterceptOnlyBeforeBarrier(t *testing.T) {
	t.Run("--help with no barrier shows CLI help, script NOT run", func(t *testing.T) {
		a, script, args := scriptRunApp(t, true)
		if err := runCLI(t, a, []string{"etl", "--help"}); err != nil {
			t.Fatal(err)
		}
		if *script != "" {
			t.Errorf("script ran (%q, %v); --help before barrier must show CLI help", *script, *args)
		}
	})

	t.Run("etl -- --help reaches the script verbatim", func(t *testing.T) {
		a, script, args := scriptRunApp(t, true)
		if err := runCLI(t, a, []string{"etl", "--", "--help"}); err != nil {
			t.Fatal(err)
		}
		if *script != "etl.sh" {
			t.Fatalf("script = %q, want etl.sh (post-barrier --help must reach the script)", *script)
		}
		if want := []string{"--help"}; !reflect.DeepEqual(*args, want) {
			t.Errorf("etl.sh argv = %v, want %v", *args, want)
		}
	})

	t.Run("--yes reset -- --whatever extracts --yes, passes --whatever", func(t *testing.T) {
		a, script, args := scriptRunApp(t, true)
		if err := runCLI(t, a, []string{"--yes", "reset", "--", "--whatever"}); err != nil {
			t.Fatal(err)
		}
		if *script != "reset.sh" {
			t.Fatalf("script = %q, want reset.sh", *script)
		}
		// reset supports --yes, so the global --yes is translated and appended;
		// --whatever passes through verbatim, the barrier is consumed.
		if want := []string{"--whatever", "--yes"}; !reflect.DeepEqual(*args, want) {
			t.Errorf("reset.sh argv = %v, want %v", *args, want)
		}
	})

	t.Run("post-barrier -h still reaches the script", func(t *testing.T) {
		a, script, args := scriptRunApp(t, true)
		if err := runCLI(t, a, []string{"status", "--", "-h"}); err != nil {
			t.Fatal(err)
		}
		if *script != "status.sh" {
			t.Fatalf("script = %q, want status.sh", *script)
		}
		if want := []string{"-h"}; !reflect.DeepEqual(*args, want) {
			t.Errorf("status.sh argv = %v, want %v", *args, want)
		}
	})
}

// A `--` before any subcommand is misuse (the README says to place it after
// the subcommand). Cobra — which parses the root command normally — strips the
// leading `--` and treats the remainder as positional args to the root, so the
// bare-invocation path runs (landing TUI on a terminal) and no script is
// dispatched. Documented as degenerate, non-destructive behavior.
func TestBarrierBeforeSubcommandIsBareInvocation(t *testing.T) {
	a, captured := tuiApp(t)
	if err := runCLI(t, a, []string{"--", "etl"}); err != nil {
		t.Fatal(err)
	}
	if captured.Start != tui.ScreenLanding {
		t.Errorf("`pic-sure -- etl` start = %v, want ScreenLanding (degenerate bare invocation)", captured.Start)
	}
}

func TestInitHelpInterceptOnlyBeforeBarrier(t *testing.T) {
	root := initFixtureRoot(t)
	// .env exists so init.sh runs directly and post-barrier args pass through.
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte("DB_MODE=local\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Run("init -- --admin-email x passes verbatim, not parsed as a field", func(t *testing.T) {
		a, calls := fakeApp(t, root, true)
		if err := a.runInit([]string{"--", "--admin-email", "x@y.org"}); err != nil {
			t.Fatal(err)
		}
		// No env-set writes: --admin-email was NOT parsed as a wizard field.
		if sets := envSetCalls(*calls); len(sets) != 0 {
			t.Errorf("env-set calls = %v, want none (post-barrier args are not fields)", sets)
		}
		last := (*calls)[len(*calls)-1]
		if last.script != "init.sh" {
			t.Fatalf("last call = %+v, want init.sh", last)
		}
		if want := []string{"--admin-email", "x@y.org"}; !reflect.DeepEqual(last.args, want) {
			t.Errorf("init.sh argv = %v, want %v (verbatim passthrough)", last.args, want)
		}
	})

	t.Run("field flag before barrier consumed; --force after passes through", func(t *testing.T) {
		a, calls := fakeApp(t, root, true)
		err := a.runInit([]string{"--release-control-branch", "X", "--", "--force"})
		if err != nil {
			t.Fatal(err)
		}
		var wroteBranch bool
		for _, c := range envSetCalls(*calls) {
			if c.args[0] == "RELEASE_CONTROL_BRANCH" {
				wroteBranch = true
			}
		}
		if !wroteBranch {
			t.Error("pre-barrier --release-control-branch must be consumed as a field write")
		}
		last := (*calls)[len(*calls)-1]
		if last.script != "init.sh" || !reflect.DeepEqual(last.args, []string{"--force"}) {
			t.Errorf("init.sh argv = %v, want [--force] (post-barrier verbatim)", last.args)
		}
	})
}

func TestTableScriptsHaveNoCollisions(t *testing.T) {
	seen := map[string]bool{}
	for _, sc := range scriptCommandTable {
		if seen[sc.Name] {
			t.Errorf("duplicate command name %q", sc.Name)
		}
		seen[sc.Name] = true
		if sc.Script == "" {
			t.Errorf("%s has no script", sc.Name)
		}
	}
}

// tuiApp builds an app whose startTUI is captured instead of executed.
func tuiApp(t *testing.T) (*app, *tui.Options) {
	t.Helper()
	var captured tui.Options
	a := &app{
		findRoot:      func(start, override string) (string, error) { return "/fake/root", nil },
		isInteractive: func() bool { return true },
		startTUI: func(o tui.Options) error {
			captured = o
			return nil
		},
	}
	return a, &captured
}

func TestBareInvocationStartsLanding(t *testing.T) {
	a, captured := tuiApp(t)
	root := a.rootCommand()
	root.SetArgs([]string{})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if captured.Start != tui.ScreenLanding {
		t.Errorf("bare invocation start = %v, want ScreenLanding", captured.Start)
	}
}

func TestDashboardSubcommandStartsDashboard(t *testing.T) {
	a, captured := tuiApp(t)
	root := a.rootCommand()
	root.SetArgs([]string{"dashboard"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if captured.Start != tui.ScreenDashboard {
		t.Errorf("dashboard subcommand start = %v, want ScreenDashboard", captured.Start)
	}
}

func TestDevCommandPassesThroughVerbatim(t *testing.T) {
	argv, err := endToEndArgv(t, "dev", []string{"up", "httpd-hmr"}, true)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"dev", "up", "httpd-hmr"}; !reflect.DeepEqual(argv, want) {
		t.Errorf("argv = %v, want %v", argv, want)
	}
}

// executeCode is a test helper that mirrors the Execute() happy/sad path:
// it runs the cobra tree and returns the exit code by applying the same
// logic Execute uses (a.exitCode if the script ran, 2 on cobra/usage errors).
func executeCode(t *testing.T, osArgs []string) int {
	t.Helper()
	cleaned, opts, err := ScanGlobalArgs(osArgs)
	if err != nil {
		return 2 // ScanGlobalArgs usage error
	}
	var ranCode int
	a := &app{
		findRoot:      func(start, override string) (string, error) { return "/fake/root", nil },
		isInteractive: func() bool { return false },
		runScript: func(root, script string, args []string) (int, error) {
			// Stub: always success (exit 0).
			return ranCode, nil
		},
	}
	a.opts = opts
	root := a.rootCommand()
	root.SetArgs(cleaned)
	root.SetOut(io.Discard)
	root.SetErr(io.Discard)
	if err := root.Execute(); err != nil {
		if a.exitCode != 0 {
			return a.exitCode
		}
		return 2
	}
	return a.exitCode
}

// TestExitCodeMatrix pins the binary's own exit codes for usage errors
// (both cobra-level and ScanGlobalArgs-level) and for script success.
// The convention: exit 2 for CLI usage errors, propagated exit code for
// scripts, matching env-set.sh and the contract's exit-code table.
func TestExitCodeMatrix(t *testing.T) {
	cases := []struct {
		name     string
		osArgs   []string
		wantCode int
	}{
		{
			name:     "unknown subcommand → 2",
			osArgs:   []string{"completely-unknown"},
			wantCode: 2,
		},
		{
			name:     "--root missing value → 2",
			osArgs:   []string{"--root"},
			wantCode: 2,
		},
		{
			name:     "reset non-interactive without --yes → 2 (usage precondition)",
			osArgs:   []string{"reset"},
			wantCode: 2,
		},
		{
			name:     "known script on non-interactive (script will run) → 0",
			osArgs:   []string{"status", "--json"},
			wantCode: 0,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := executeCode(t, tc.osArgs)
			if got != tc.wantCode {
				t.Errorf("exit code = %d, want %d", got, tc.wantCode)
			}
		})
	}
}
