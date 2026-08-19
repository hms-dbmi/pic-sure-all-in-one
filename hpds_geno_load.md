# Loading Genomic Data into HPDS

Genomic loads run through `./etl.sh` from this checkout. There is no Jenkins
server. See [docs/etl.md](docs/etl.md) for the full command reference.

## Prepare your source data

You need two things:

- `vcfIndex.tsv` — describes the VCF file(s) to load. For the format, see
  [pic-sure-hpds-genotype-load-example](https://github.com/hms-dbmi/pic-sure-hpds-genotype-load-example#loading-your-vcf-data-into-hpds).
- a directory containing the VCF file(s) to be read and converted to the HPDS
  format.

Both live wherever you like on the host; you pass their paths as flags.

## Load

The `load-genomic` orchestrator validates every input before it touches HPDS,
then stages the load, promotes it, and enables the genomic profile:

```bash
./etl.sh load-genomic \
  --partition my_partition \
  --vcf-index /path/vcfIndex.tsv \
  --vcf-dir /path/to/vcfs \
  [--heap 16000] [--promote] [--enable-profile]
```

- `--partition` must match `^[A-Za-z0-9_-]+$`; `--heap` defaults to `16000`.
- Without `--promote`, the load only stages into `.data/vcf-load/` — nothing in
  the running HPDS changes yet.
- `--enable-profile` sets `HPDS_PROFILE=bch-dev` and restarts HPDS, as the last
  step. Enabling that profile without promoted genomic data crash-loops HPDS, so
  the orchestrator warns if you pass it without `--promote`.

This can take a long time; heap and disk are the usual constraints.

To run the steps individually — for recovery, or to inspect the staged output
before it goes live:

```bash
./etl.sh load-vcf --partition my_partition --vcf-index /path/vcfIndex.tsv --vcf-dir /path/to/vcfs --heap 16000
./etl.sh promote-genomic [--backup-current-data] [--clean]
```

`promote-genomic` copies the staged partition into the `hpds-genomic` volume,
which HPDS mounts at `/opt/local/hpds/all`. Add `--backup-current-data` only
when there is disk for a second copy of the current genomic data.

## Moving genomic data between environments

Genomic data lives in the `hpds-genomic` Docker volume, not on the host
filesystem. To copy it between environments (for example, promoting tested
development data to production), export the volume from the source host and
import it on the target:

The volume name is prefixed with the Compose project name. Resolve it
explicitly from your `.env` — never pick one from a `docker volume ls`
listing, because a host with more than one deployment has more than one
`hpds-genomic` volume and the import below wipes whichever volume it is
pointed at:

```bash
# Both hosts: resolve this deployment's volume name from .env
GENOMIC_VOLUME="$(. ./.env 2>/dev/null; echo "${COMPOSE_PROJECT_NAME:-picsure}_hpds-genomic")"
docker volume inspect "$GENOMIC_VOLUME" >/dev/null   # fails if the name is wrong

# On the source host
docker run --rm -v "$GENOMIC_VOLUME":/data:ro \
  -v "$PWD":/out alpine tar czf /out/hpds-genomic.tgz -C /data .

# On the target host, with the stack stopped
docker compose down
docker run --rm -v "$GENOMIC_VOLUME":/data \
  -v "$PWD":/in alpine sh -c 'rm -rf /data/* && tar xzf /in/hpds-genomic.tgz -C /data'
docker compose up -d
```
