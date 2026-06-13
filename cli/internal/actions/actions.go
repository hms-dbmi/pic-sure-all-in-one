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
		"public-1000genomes": "Prints the manual steps for loading the public 1000 Genomes\ngenomic dataset — downloads nothing and changes nothing.",
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
// confirmed). Sibling repos are untouched.
func Reset() Action { return ResetWith(false, false) }

// ResetAll: reset.sh --all — everything Reset does, PLUS the database volume,
// the PIC-SURE images, and the Maven build cache. Same typed-word gate as Reset
// (the UI distinguishes them by label and destruction text, not the word).
func ResetAll() Action { return ResetWith(true, false) }

// ResetWith builds a reset action parameterized by scope and the repo toggle,
// the way DemoData parameterizes by dataset:
//   - all=false → DB-preserving reset; all=true → reset.sh --all (full wipe)
//   - repos=true → also git-resets the sibling checkouts to their release refs
//     (reset.sh --repos): uncommitted changes are discarded, but local branches
//     and git history are KEPT. .git is never deleted (that is uninstall --repos).
//
// Reset()/ResetAll() are the zero-arg convenience wrappers for the common
// repos-off case (the dashboard and CLI use those); the combined TUI reset
// dialog calls ResetWith directly when its repo toggle is on.
func ResetWith(all, repos bool) Action {
	name := "reset"
	args := []string{}
	if all {
		name = "reset --all"
		args = append(args, "--all")
	}
	if repos {
		name += " --repos"
		args = append(args, "--repos")
	}
	args = append(args, "--yes")

	var describe string
	if all {
		describe = "FULL WIPE. Stops all containers and DELETES everything Reset does, PLUS:\n" +
			"  • the database volume (picsure-db data — ALL loaded phenotype data is lost)\n" +
			"  • every PIC-SURE image\n" +
			"  • the Maven build cache (next init rebuilds from source — slow)\n" +
			".env is backed up first; certs/, .data/, and generated config are removed too."
	} else {
		describe = "Stops all containers and DELETES:\n" +
			"  • every project volume EXCEPT the database volume (picsure-db data kept)\n" +
			"  • .env (backed up first), certs/, .data/\n" +
			"  • generated config: dictionary.env, HPDS encryption key, truststores,\n" +
			"    visualization resource.properties, deployed WARs"
	}
	// The repos sentence and the kept sentence are alternatives — never both
	// (saying "sibling repos are kept" while also resetting them was a bug).
	if repos {
		describe += "\nSibling repos are reset to their release refs: uncommitted changes are\n" +
			"discarded, but local branches and git history are KEPT. .env.example is kept."
	} else {
		describe += "\nSibling repos and .env.example are kept."
	}

	return Action{
		Name:        name,
		Script:      scripts.Reset,
		Args:        args,
		Destructive: true,
		ConfirmWord: "reset",
		Describe:    describe,
		AbortNote:   "partial cleanup possible; run `pic-sure status` to see what remains.",
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
			"NOTE: `uninstall --repos` DELETES repos/ INCLUDING local git history —\n" +
			"use `pic-sure reset --repos` to reset working trees instead of deleting.\n" +
			"Remote databases are not touched.",
		AbortNote: "partial removal possible; run `pic-sure status`, then re-run uninstall.",
	}
}

// PhenotypeOpts holds all optional parameters for LoadPhenotype. Only the
// File field is required; every other field is omitted from the argv when
// empty/zero, letting etl.sh's own defaults take effect.
type PhenotypeOpts struct {
	// File is the path to the phenotype CSV (required). May be a raw .csv, a
	// gzip (.gz/.csv.gz), or a gzipped tar (.tgz/.tar.gz) — etl.sh detects the
	// form by content.
	File string
	// ArchiveEntry selects which CSV to load from a tar that holds more than one
	// (forwarded as --entry). Must match an `etl.sh archive-csvs` line verbatim
	// (including any subdir prefix). Empty lets etl.sh auto-pick a single-CSV tar
	// or decompress a plain gzip.
	ArchiveEntry string
	// Heap is the JVM heap size string passed verbatim as --heap (e.g. "16g").
	// Empty means: let etl.sh default.
	Heap string
	// CustomDictionary switches from auto-hydrate mode to custom-dictionary
	// mode. When true, Datasets+Concepts (and optionally Facets* fields) are
	// forwarded as --datasets/--concepts/--facets-categories/--facets/
	// --facet-concepts.
	CustomDictionary bool
	// Datasets and Concepts are the custom CSV/ZIP paths; only used when
	// CustomDictionary is true.
	Datasets string
	Concepts string
	// FacetCategories, Facets, FacetConcepts are the three optional facet
	// CSVs; only forwarded when CustomDictionary is true and each field is
	// non-empty.
	FacetCategories string
	Facets          string
	FacetConcepts   string
	// SkipWeights omits the search-weight rebuild step when true.
	SkipWeights bool
}

// GenomicOpts holds all parameters for LoadGenomic. Partition and VCFIndex
// are required; everything else is omitted from the argv when empty/zero.
type GenomicOpts struct {
	// Partition is the named genomic partition (required).
	Partition string
	// VCFIndex is the path to the VCF index TSV (required).
	VCFIndex string
	// VCFDir is an optional directory override for VCF files.
	VCFDir string
	// Heap is the JVM heap size string passed verbatim as --heap. Empty means
	// let etl.sh default.
	Heap string
	// Promote runs the promote step (backup-safe: stages atomically).
	Promote bool
	// EnableProfile enables the genomic HPDS profile (HPDS_PROFILE=bch-dev) and
	// restarts HPDS so loaded genomic data becomes queryable; caveat: enabling
	// it before genomic data is present crash-loops HPDS.
	EnableProfile bool
}

// LoadPhenotype loads a phenotype CSV into HPDS and rebuilds the dictionary.
//
// Destructive note: this action REPLACES existing HPDS phenotype data.  The
// wizard's confirm-summary is the consent screen (same pattern as Init and
// DemoData), so Destructive and ConfirmWord are left unset — the caller owns
// the consent step. The Describe text makes the replacement explicit so the
// wizard author can surface it prominently.
func LoadPhenotype(o PhenotypeOpts) Action {
	args := []string{"load-phenotype", "--file", o.File}
	if o.Heap != "" {
		args = append(args, "--heap", o.Heap)
	}
	// --entry selects one CSV from a multi-CSV tar; positioned per etl.sh's
	// documented load-phenotype order (--file [--heap] [--entry] [--dictionary]).
	if o.ArchiveEntry != "" {
		args = append(args, "--entry", o.ArchiveEntry)
	}
	if o.CustomDictionary {
		args = append(args, "--dictionary", "custom")
		if o.Datasets != "" {
			args = append(args, "--datasets", o.Datasets)
		}
		if o.Concepts != "" {
			args = append(args, "--concepts", o.Concepts)
		}
		if o.FacetCategories != "" {
			args = append(args, "--facets-categories", o.FacetCategories)
		}
		if o.Facets != "" {
			args = append(args, "--facets", o.Facets)
		}
		if o.FacetConcepts != "" {
			args = append(args, "--facet-concepts", o.FacetConcepts)
		}
	}
	if o.SkipWeights {
		args = append(args, "--skip-weights")
	}

	describe := "REPLACES existing HPDS phenotype data with the provided CSV, then\n" +
		"rebuilds the dictionary database"
	if o.CustomDictionary {
		describe += " using the supplied custom dictionary CSVs"
	} else {
		describe += " via auto-hydrate"
	}
	describe += ".\nFinal step: recomputes search weights"
	if o.SkipWeights {
		describe += " (skipped by --skip-weights)."
	} else {
		describe += "."
	}

	return Action{
		Name:   "load phenotype data",
		Script: scripts.Etl,
		Args:   args,
		// Destructive/ConfirmWord intentionally unset: the load-your-data
		// wizard confirm-summary is the consent step, matching the Init and
		// DemoData pattern. The Describe text above calls out the replacement
		// explicitly so the wizard can surface it.
		Describe:  describe,
		AbortNote: "partial load possible; phenotype CSV may be loaded but dictionary not rebuilt — re-run from Load your data or `pic-sure etl hydrate-dictionary`.",
	}
}

// LoadGenomic loads VCF data for a named genomic partition.
func LoadGenomic(o GenomicOpts) Action {
	args := []string{"load-genomic", "--partition", o.Partition, "--vcf-index", o.VCFIndex}
	if o.VCFDir != "" {
		args = append(args, "--vcf-dir", o.VCFDir)
	}
	if o.Heap != "" {
		args = append(args, "--heap", o.Heap)
	}
	if o.Promote {
		args = append(args, "--promote")
	}
	if o.EnableProfile {
		args = append(args, "--enable-profile")
	}

	describe := fmt.Sprintf("Loads VCF data for genomic partition %q into HPDS staging.", o.Partition)
	if o.Promote {
		describe += "\n--promote is set: the staged data is promoted into the live volume\n" +
			"atomically (backup-safe — the previous data volume is preserved as a\n" +
			"sibling until explicitly removed)."
	} else {
		describe += "\nStaging only — run `pic-sure etl promote-genomic` to make it live."
	}
	if o.EnableProfile {
		describe += "\n--enable-profile is set: enables the genomic HPDS profile\n" +
			"(HPDS_PROFILE=bch-dev) and restarts HPDS so loaded genomic data is\n" +
			"queryable. Caveat: enabling the profile before genomic data is present\n" +
			"crash-loops HPDS — only enable it once promoted data exists."
	}

	return Action{
		Name:      "load genomic data",
		Script:    scripts.Etl,
		Args:      args,
		Describe:  describe,
		AbortNote: fmt.Sprintf("partial VCF load possible for partition %q; staging is incomplete — re-run LoadGenomic to restart, or `pic-sure etl promote-genomic` if load finished but promote was skipped.", o.Partition),
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
