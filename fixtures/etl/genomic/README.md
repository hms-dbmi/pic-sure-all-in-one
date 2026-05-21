# Genomic ETL Fixture Gate

Jenkins retirement is blocked until this directory contains a tiny public or
synthetic genomic fixture that can exercise:

- `./etl.sh load-vcf --partition <name> --vcf-index <vcfIndex.tsv> --vcf-dir <dir>`
- `./etl.sh promote-genomic`

The fixture must not contain patient data and should be small enough to run as a
local smoke test.
