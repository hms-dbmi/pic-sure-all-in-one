// Package scripts is the single registry of bash script paths (relative to
// the checkout root). The CLI command table, the init wizard, and the
// dashboard all reference these constants so a script rename cannot leave
// one consumer pointing at a stale path.
package scripts

const (
	Init           = "init.sh"
	Update         = "update.sh"
	Status         = "status.sh"
	Preflight      = "preflight.sh"
	Etl            = "etl.sh"
	Reset          = "reset.sh"
	Uninstall      = "uninstall.sh"
	ReleaseControl = "release-control.sh"
	SeedDB         = "seed-db.sh"
	Migrate        = "run-migrations.sh"
	DemoData       = "load-demo-data.sh"
	Compose        = "scripts/compose.sh"
	EnvSet         = "scripts/env-set.sh"
)
