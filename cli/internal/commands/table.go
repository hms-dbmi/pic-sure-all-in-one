package commands

import "github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"

// scriptCommandTable maps subcommands 1:1 to the operational scripts.
// FlagsHelp is hand-maintained documentation only — flags are never parsed
// by the binary, so keep these in sync with the scripts' usage headers.
// init is not in this table: it has its own wizard-aware command (init.go).
var scriptCommandTable = []ScriptCommand{
	{
		Name:      "update",
		Script:    scripts.Update,
		Short:     "Safely update sources, images, migrations, and services",
		FlagsHelp: "--dry-run  --offline  --no-rebuild  --pull-images  --verbose",
	},
	{
		Name:      "status",
		Script:    scripts.Status,
		Short:     "Show configuration, repo, service, and migration status",
		FlagsHelp: "--json (machine-readable; see docs/cli-contract.md)",
	},
	{
		Name:      "preflight",
		Script:    scripts.Preflight,
		Short:     "Validate host tools and configuration without changing anything",
		FlagsHelp: "--network  --json",
	},
	{
		Name:      "etl",
		Script:    scripts.Etl,
		Short:     "Run ETL operations (load-csv, load-vcf, hydrate-dictionary, ...)",
		FlagsHelp: "SUBCOMMAND [flags] — run `pic-sure etl` with no arguments for the list",
	},
	{
		Name:        "reset",
		Script:      scripts.Reset,
		Short:       "Tear down containers and generated config (keeps the DB unless --all)",
		FlagsHelp:   "--all  --yes",
		SupportsYes: true,
		Prompts:     true,
	},
	{
		Name:        "uninstall",
		Script:      scripts.Uninstall,
		Short:       "Remove the stack, volumes (incl. DB), and generated state",
		FlagsHelp:   "--yes (required to act)  --keep-env  --images  --repos",
		SupportsYes: true,
	},
	{
		Name:      "release-control",
		Script:    scripts.ReleaseControl,
		Short:     "Resolve component refs from release control and apply to repos",
		FlagsHelp: "--dry-run  --resolve-only  --apply-only  --branch BRANCH",
	},
	{
		Name:   "seed-db",
		Script: scripts.SeedDB,
		Short:  "Seed the database (baseline migrations, admin user; idempotent)",
	},
	{
		Name:      "migrate",
		Script:    scripts.Migrate,
		Short:     "Run Flyway database migrations",
		FlagsHelp: "--check  --repair  --no-restart  --bootstrap-remote-db",
	},
	{
		Name:      "demo-data",
		Script:    scripts.DemoData,
		Short:     "Load a demo dataset into HPDS and the dictionary",
		FlagsHelp: "[nhanes|synthea|1000genomes]  --all  --verbose",
	},
	{
		Name:      "up",
		Script:    scripts.Compose,
		Prepend:   []string{"up"},
		Short:     "Start services (docker compose up -d)",
		FlagsHelp: "[SERVICE...]",
	},
	{
		Name:      "dev",
		Script:    scripts.Compose,
		Prepend:   []string{"dev"},
		Short:     "Run a service from local source via a dev compose overlay",
		FlagsHelp: "list | up OVERLAY | off SERVICE_OR_OVERLAY",
	},
	{
		Name:      "down",
		Script:    scripts.Compose,
		Prepend:   []string{"down"},
		Short:     "Stop and remove containers",
		FlagsHelp: "[docker compose down flags]",
	},
	{
		Name:      "restart",
		Script:    scripts.Compose,
		Prepend:   []string{"restart"},
		Short:     "Restart services",
		FlagsHelp: "[SERVICE...]",
	},
}
