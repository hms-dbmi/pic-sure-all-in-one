// Package actions defines the script-backed operations shared by the TUI
// surfaces (dashboard pane and activity screen) and the PTY runner that
// executes them. Every action runs a real script — no Go-side semantics
// (docs/cli-contract.md). Destructive actions must be confirmed by typing
// ConfirmWord and clearly state what is destroyed; every action carries an
// AbortNote so a confirmed abort never leaves the user guessing about state.
package actions

import (
	"fmt"
	"strings"

	"github.com/hms-dbmi/pic-sure-all-in-one/cli/internal/scripts"
)

// Action is one runnable operation.
type Action struct {
	Name        string
	Script      string // relative to root
	Args        []string
	Destructive bool
	ConfirmWord string
	Describe    string // shown in the confirm dialog
	AbortNote   string // shown after a confirmed mid-run abort
}

// Init runs the full first-time setup (or a re-run after reconfiguration).
// The wizard's confirm-summary is the consent step, so no separate confirm
// dialog is shown before this action.
func Init() Action {
	return Action{
		Name:   "setup (init.sh)",
		Script: scripts.Init,
		Describe: "Generates secrets and config, clones/builds service images,\n" +
			"starts the stack, and seeds the database. Idempotent.",
		AbortNote: "init.sh is safe to re-run; it resumes from the current state.",
	}
}

func Update() Action {
	return Action{
		Name:   "update",
		Script: scripts.Update,
		Describe: "Safe update: resolves release-control refs, rebuilds images,\n" +
			"runs migrations, rotates the introspection token, restarts services.\n" +
			"Data volumes are not deleted.",
		AbortNote: "update.sh is safe to re-run; it resumes from the current state.",
	}
}

func Restart(service string) Action {
	return Action{
		Name:      "restart " + service,
		Script:    scripts.Compose,
		Args:      []string{"restart", service},
		Describe:  fmt.Sprintf("Restarts the %s service via docker compose.", service),
		AbortNote: "the service may be mid-restart; check its state in the dashboard.",
	}
}

func Preflight() Action {
	return Action{
		Name:      "preflight",
		Script:    scripts.Preflight,
		Describe:  "Non-mutating host/config validation.",
		AbortNote: "preflight is read-only; nothing changed.",
	}
}

func Migrate() Action {
	return Action{
		Name:      "migrate",
		Script:    scripts.Migrate,
		Describe:  "Runs Flyway database migrations, then restarts wildfly/psama\nif they are running.",
		AbortNote: "re-run migrate; Flyway resumes pending migrations (pass --repair via `pic-sure migrate --repair` if it reports a failed row).",
	}
}

func SeedDB() Action {
	return Action{
		Name:      "seed-db",
		Script:    scripts.SeedDB,
		Describe:  "Seeds baseline migrations, the admin user, and the visualization\nresource. Idempotent — safe to re-run.",
		AbortNote: "seed-db is idempotent; safe to re-run.",
	}
}

func DemoData(dataset string) Action {
	args := []string{}
	if dataset == "all" {
		args = append(args, "--all")
	} else {
		args = append(args, dataset)
	}
	return Action{
		Name:   "demo-data " + dataset,
		Script: scripts.DemoData,
		Args:   args,
		Describe: "REPLACES the phenotype data in the hpds-data volume with the\n" +
			"selected demo dataset, then re-hydrates the dictionary database.",
		AbortNote: "demo data may be partially loaded; re-run to load it completely.",
	}
}

// Etl runs one parameterless etl.sh subcommand. The subcommands that need
// file arguments (load-csv, load-vcf, ...) stay CLI-only — see etl.sh -h.
func Etl(sub string) Action {
	describe := map[string]string{
		"hydrate-dictionary": "Re-hydrates the dictionary database from the currently loaded\nHPDS data.",
		"run-weights":        "Recomputes dictionary search weights using the default weights\nfile from the dictionary repo.",
		"promote-genomic":    "Promotes staged genomic data into the live HPDS data volume.",
		"public-1000genomes": "Loads the public 1000 Genomes genomic dataset (large download,\nlong run).",
	}[sub]
	abort := map[string]string{
		"promote-genomic": "promotion may be partial; check the HPDS data state before re-running.",
	}[sub]
	if abort == "" {
		abort = "etl.sh " + sub + " was interrupted; it is safe to re-run."
	}
	return Action{
		Name:      "etl " + sub,
		Script:    scripts.Etl,
		Args:      []string{sub},
		Describe:  describe,
		AbortNote: abort,
	}
}

// ReleaseControlApply re-resolves and applies the current release-control
// branch's refs (checkouts move; images rebuild on the next update).
func ReleaseControlApply() Action {
	return Action{
		Name:      "release-control apply",
		Script:    scripts.ReleaseControl,
		Describe:  "Resolves the current release-control branch's refs and applies\nthem to the sibling checkouts. Run update afterwards to rebuild.",
		AbortNote: "re-run release-control; resolution and apply are idempotent.",
	}
}

// ReleaseControlDryRun resolves without applying.
func ReleaseControlDryRun() Action {
	return Action{
		Name:      "release-control dry run",
		Script:    scripts.ReleaseControl,
		Args:      []string{"--dry-run"},
		Describe:  "Resolves the release-control refs and reports what would change\nwithout touching any checkout.",
		AbortNote: "dry run is read-only; nothing changed.",
	}
}

// ReleaseControlBranch switches the release-control branch, then resolves
// and applies it.
func ReleaseControlBranch(branch string) Action {
	return Action{
		Name:      "release-control --branch " + branch,
		Script:    scripts.ReleaseControl,
		Args:      []string{"--branch", branch},
		Describe:  "Switches the release-control branch to '" + branch + "', resolves its\nrefs, and applies them to the sibling checkouts.",
		AbortNote: "re-run release-control; resolution and apply are idempotent.",
	}
}

// DevUp recreates one service from local source using a dev compose overlay
// (scripts/compose.sh dev up: base files + the overlay, up -d --no-deps
// --build). One-shot by design: a later plain up or update recreates the
// service from the release image.
func DevUp(overlay string) Action {
	return Action{
		Name:   "dev overlay " + overlay,
		Script: scripts.Compose,
		Args:   []string{"dev", "up", overlay},
		Describe: "Recreates the overlay's service from LOCAL SOURCE\n" +
			"(docker-compose.dev-" + overlay + ".yml on top of the base files;\n" +
			"up -d --no-deps --build). One-shot: a later plain up or update\n" +
			"reverts the service to the release image.",
		AbortNote: "the service may be mid-recreate; re-run the overlay, or revert it to the release image.",
	}
}

// DevOff recreates a service from the release image (base compose files
// only). Accepts a service or an overlay name — the script resolves it.
func DevOff(name string) Action {
	return Action{
		Name:      "revert " + name,
		Script:    scripts.Compose,
		Args:      []string{"dev", "off", name},
		Describe:  fmt.Sprintf("Recreates %s from the release image (base compose files only).", name),
		AbortNote: "the service may be mid-recreate; re-run the revert.",
	}
}

// Reset: destruction description matches reset.sh (backs up .env, removes
// containers, all picsure_* volumes EXCEPT the database volume, certs/,
// .data/, generated config; --yes is appended because the UI already
// confirmed).
func Reset() Action {
	return Action{
		Name:        "reset",
		Script:      scripts.Reset,
		Args:        []string{"--yes"},
		Destructive: true,
		ConfirmWord: "reset",
		Describe: "Stops all containers and DELETES:\n" +
			"  • every project volume EXCEPT the database volume (picsure-db data kept)\n" +
			"  • .env (backed up first), certs/, .data/\n" +
			"  • generated config: dictionary.env, HPDS encryption key, truststores,\n" +
			"    visualization resource.properties, deployed WARs\n" +
			"Sibling repos and .env.example are kept.",
		AbortNote: "partial cleanup possible; run `pic-sure status` to see what remains.",
	}
}

// ResetAll: reset.sh --all — everything Reset does, PLUS the database volume,
// the PIC-SURE images, and the Maven build cache. Same typed-word gate as Reset
// (the UI distinguishes them by label and destruction text, not the word).
func ResetAll() Action {
	return Action{
		Name:        "reset --all",
		Script:      scripts.Reset,
		Args:        []string{"--all", "--yes"},
		Destructive: true,
		ConfirmWord: "reset",
		Describe: "FULL WIPE. Stops all containers and DELETES everything Reset does, PLUS:\n" +
			"  • the database volume (picsure-db data — ALL loaded phenotype data is lost)\n" +
			"  • every PIC-SURE image\n" +
			"  • the Maven build cache (next init rebuilds from source — slow)\n" +
			".env is backed up first; certs/, .data/, and generated config are removed too.\n" +
			"Sibling repos and .env.example are kept.",
		AbortNote: "partial cleanup possible; run `pic-sure status` to see what remains.",
	}
}

// Uninstall: matches uninstall.sh --yes (compose down --volumes INCLUDING the
// database volume; .env backed up then removed; generated files removed;
// repos and images kept without extra flags).
func Uninstall() Action {
	return Action{
		Name:        "uninstall",
		Script:      scripts.Uninstall,
		Args:        []string{"--yes"},
		Destructive: true,
		ConfirmWord: "uninstall",
		Describe: "Removes the Compose stack and DELETES:\n" +
			"  • all containers, networks, and volumes INCLUDING the database volume\n" +
			"  • .env (backed up first)\n" +
			"  • certs/, .data/, init.log, and all generated config\n" +
			"Cloned repos and local images are kept (use the CLI for --repos/--images).\n" +
			"Remote databases are not touched.",
		AbortNote: "partial removal possible; run `pic-sure status`, then re-run uninstall.",
	}
}

// ConfirmAccepted decides whether a completed confirm dialog authorizes the
// action: destructive actions require the typed word to match exactly (the
// yes/no flag is never bound for them); everything else uses the flag.
func ConfirmAccepted(act Action, ok bool, text string) bool {
	if act.Destructive {
		return strings.TrimSpace(text) == act.ConfirmWord
	}
	return ok
}
