# Data Dictionary

## What is it?

The Data Dictionary is an API that provides information about the variables stored in a PIC-SURE environment. It
provides both faceted search and keyword search. 

## Architecture

The Data Dictionary consists of two main services — `dictionary-api` and
`dictionary-db` — plus two secondary ones, `dictionary-dump` and
`dictionaryetl`.

- `dictionary-api`: a read-only REST API that returns facets, concepts, and their metadata for user searches. Built from `pic-sure/services/picsure-dictionary`. Browsers never reach it directly: the gateway routes `/dictionary` to it, and `httpd` proxies `/picsure/*` to the gateway.
- `dictionary-db`: a PostgreSQL 16 database storing the data the API returns. Its baseline DDL is `pic-sure/services/picsure-dictionary/db/schema.sql`; `flyway-dictionary-init` applies the migrations in `db/flyway` on top of it at startup.
- `dictionary-dump`: enables dumping and pulling remote dictionaries. Only for distributed PIC-SURE environments.
- `dictionaryetl`: populates the Postgres database. Not a Compose service — `etl.sh` and `load-demo-data.sh` build it from the `picsure-dictionary-etl` repo and run it as a transient container for the duration of a load.

`dictionary-api`, `dictionary-db`, `dictionary-dump`, and
`flyway-dictionary-init` share the internal `data` network and the generated
`config/dictionary/dictionary.env` credentials.

To explore the Dictionary schema, connect to the database — see
[db-access.md](db-access.md) for the exact command. The tables live under the
`dict` schema, so run `set search_path to dict;` first, then `\dt`.

## How do I load data into it?

There are two ways to load data into the Data Dictionary. You can either have the ETL pull concepts directly from HPDS,
or you can upload your own concepts, facets, and metadata via CSV.

Both paths run through `etl.sh`; there are no Jenkins jobs. See
[etl.md](etl.md) for the full command reference.

### Direct from HPDS
Pulling directly from HPDS is less error-prone, but it doesn't allow you to customise the output. If you have important
metadata for your concepts that you want to search on, or you have custom display names, this may not be right for you.

The `load-phenotype` orchestrator does this as part of a phenotype load — it is
the recommended entry point:

```bash
./etl.sh load-phenotype --file /path/allConcepts.csv --dictionary auto
```

To hydrate an already-loaded HPDS without touching phenotype data, run the two
atomic steps directly:

```bash
./etl.sh hydrate-dictionary --include-dataset-facets --clear
./etl.sh run-weights
```

### Build from CSV
Building from CSV allows you to add custom facets, change the names of concepts, and add metadata to enhance search:

```bash
./etl.sh load-phenotype --file /path/allConcepts.csv --dictionary custom \
  --datasets /path/datasets.csv --concepts /path/concepts.zip \
  [--facets-categories /path/facet_categories.csv \
   --facets /path/facets.csv \
   --facet-concepts /path/facet_concepts.csv]
```

Or as atomic steps against an existing HPDS load:

```bash
./etl.sh load-dictionary-csv --datasets /path/datasets.csv --concepts /path/concepts.zip --clear
./etl.sh load-facets --categories /path/facet_categories.csv --facets /path/facets.csv --concepts /path/facet_concepts.csv
./etl.sh run-weights
```

`--datasets` takes a single `datasets.csv`. `--concepts` takes a **zip**
containing one or more `concepts_*.csv` files; their schema is below.
The datasets CSV has the following schema:
```csv
"ref","full_name","abbreviation","description"
"dataset_internal_name","Dataset Display Name","IDK","This is a description of the dataset"
```
The concepts CSV has the following schema:
```csv
"dataset_ref","name","display","concept_type","concept_path","parent_concept_path","values","description"
"dataset_internal_name","concept_node_name","Concept Node Display","categorical","\\Concept\\Path\\","\\Concept\\","comma,delimited,list","This is a description"
```
This schema is more complex. Here are some notes:
- `dataset_ref` should match the `ref` column from the datasets CSV
- `name` and `display` are as expected
- `concept_type`: This can be either `categorical` or `continious`. Default to `categorical`, use `continious` if this
concept only has numeric values.
- `concept_path` and `parent_concept_path`: You are constructing a hierarchy of concepts in this CSV. This hierarchy
is defined using these concept paths. There should be a root concept path (probably `\\`), and then a series of concepts
that extend from there.
  - Every non-root concept must have a parent, and that parent must appear before it in the CSV
  - A parent `p` for the current row `c` is a CSV row where `p.concept_path` = `c.parent_concept_path`. It must match
  exactly.
  - Using `\\` as a node delimiter is standard, but not required. Just be consistent with your delimiter
  - While all concepts are displayed in ontological views in the UI, only concepts with values will be displayed as 
  search results
- `values`: this is a metadata field, so it is _technically_ optional. That said, if you do not populate this, your
concepts will not be displayed. This should be a comma-delimited list of all the possible values for the concept. If
the concept is numeric / continuous, it should instead be `min,max`
- `description`, etc: metadata fields. Add as many as you want. Values added to these metadata fields can enhance search.
Example: you could add a `LOINC` metadata field and add LOINC codes to specific concepts. This will allow you to search
for those LOINC codes in the UI.