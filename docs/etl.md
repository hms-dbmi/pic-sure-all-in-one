# ETL Operations

`etl.sh` is the Compose replacement for the Jenkins ETL jobs. Run commands from
the repository root after `./init.sh`.

## Phenotype HPDS Loads

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

## Dictionary Loads

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

## Genomic Loads

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
