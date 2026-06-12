# ETL Operations

`etl.sh` is the Compose replacement for the Jenkins ETL jobs. Run commands from
the repository root after `./init.sh`.

## Orchestrators (recommended)

Two orchestrators chain the happy path end to end and are the recommended entry
points. They validate **all** inputs up front — before any HPDS mutation — so a
typo never half-loads the stack, then run the atomic steps in order and surface
which step failed (with the single command to re-run just that step). The
atomic subcommands documented below remain available for advanced/recovery use.

These are the same orchestrators the `pic-sure` CLI's guided **Load your data**
wizard streams — see the
[walkthrough in `cli/README.md`](../cli/README.md#load-your-data) for the
end-to-end TUI flow (the wizard simply collects these flags for you).

### `load-phenotype`

Load a phenotype CSV, hydrate or load the dictionary, then run weights:

```bash
./etl.sh load-phenotype --file /path/allConcepts.csv [--heap 4096] \
  [--dictionary auto|custom] \
  [--datasets /path/datasets.csv --concepts /path/concepts.zip] \
  [--facets-categories /path/facet_categories.csv \
   --facets /path/facets.csv \
   --facet-concepts /path/facet_concepts.csv] \
  [--skip-weights]
```

- `--heap` defaults to `4096`; `--dictionary` defaults to `auto`.
- `auto` hydrates the dictionary from HPDS (`hydrate-dictionary --clear`).
- `custom` loads ingest CSVs (`load-dictionary-csv … --clear`); the facet trio
  is all-or-none and, when given, runs `load-facets` after the dictionary load.
- `--skip-weights` omits the final `run-weights` step.

Step 1 (`load-csv`) stops and restarts HPDS itself; if a later step fails, HPDS
is already back up — the failure message says so.

### `load-genomic`

Stage a VCF load, optionally promote it, and optionally enable the genomic
profile:

```bash
./etl.sh load-genomic --partition my_partition --vcf-index /path/vcfIndex.tsv \
  [--vcf-dir /path/to/vcfs] [--heap 16000] [--promote] [--enable-profile]
```

- `--heap` defaults to `16000`; `--partition` must match `^[A-Za-z0-9_-]+$`.
- `--promote` runs `promote-genomic --backup-current-data` (always the backed-up
  form from this path).
- `--enable-profile` sets `HPDS_PROFILE=bch-dev` (via `scripts/env-set.sh`) and
  restarts HPDS — the last step. Enabling the profile without promoted genomic
  data crash-loops HPDS, so the orchestrator warns when `--enable-profile` is
  set without `--promote`.

## Advanced / atomic operations

The subcommands below are the individual steps the orchestrators above chain
together. Prefer `load-phenotype` / `load-genomic` for normal loads; reach for
these directly only for advanced or recovery use (e.g. re-running a single
failed step).

### Phenotype HPDS Loads

Single CSV:

```bash
./etl.sh load-csv --file /path/allConcepts.csv --heap 4096
```

Multiple CSV/SQL input directory:

```bash
./etl.sh load-multiple --input-dir /path/hpds_input --heap 8000
```

RDBMS source:

```bash
./etl.sh load-rdbms \
  --sql-properties /path/sql.properties \
  --query /path/loadQuery.sql \
  --heap 20480
```

These commands replace phenotype HPDS data, matching the old Jenkins loader
behavior. Large HPDS backups are not automatic.

### Dictionary Loads

Hydrate dictionary metadata from HPDS:

```bash
./etl.sh hydrate-dictionary --include-dataset-facets --clear
```

Load dictionary ingest CSVs:

```bash
./etl.sh load-dictionary-csv \
  --datasets /path/datasets.csv \
  --concepts /path/concepts.zip \
  --clear
```

Load facet CSVs:

```bash
./etl.sh load-facets \
  --categories /path/facet_categories.csv \
  --facets /path/facets.csv \
  --concepts /path/facet_concepts.csv
```

Run dictionary weights:

```bash
./etl.sh run-weights
```

### Genomic Loads

Load VCF data into the staging area:

```bash
./etl.sh load-vcf \
  --partition my_partition \
  --vcf-index /path/vcfIndex.tsv \
  --vcf-dir /path/to/vcfs \
  --heap 16000
```

Promote staged genomic data into the runtime HPDS genomic volume:

```bash
./etl.sh promote-genomic --clean
```

Add `--backup-current-data` only when there is enough disk for a second copy of
the current genomic data.

## Smoke Fixtures

Tiny non-sensitive phenotype and dictionary fixtures live under
`fixtures/etl/custom/`.

```bash
./scripts/smoke-matrix.sh --include-etl
```

Genomic Jenkins retirement remains gated on adding a tiny public or synthetic
fixture under `fixtures/etl/genomic/`.
