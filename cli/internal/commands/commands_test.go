package commands

import (
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
			name:     "-- stops global scanning; remainder passes verbatim",
			in:       []string{"etl", "--", "--root", "/x", "--yes"},
			wantArgs: []string{"etl", "--root", "/x", "--yes"},
		},
		{
			name:     "globals before -- still apply",
			in:       []string{"--root", "/r", "reset", "--", "--yes"},
			wantArgs: []string{"reset", "--yes"},
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
