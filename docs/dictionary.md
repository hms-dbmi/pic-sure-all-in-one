# Data Dictionary

## What is it?

The Data Dictionary is an API that provides information about the variables stored in a PIC-SURE environment. It
provides both faceted search and keyword search. 

## Architecture

The Data Dictionary consists of two main services- `dictionary-api`, and `dictionary-db`, as well as two secondary
services, `dictionary-dump`, and `dictionaryetl`.

- `dictionary-api`: a read only REST API that returns facets, concepts, and their metadata for user searches
- `dictionary-db`: a Postgres database used to store the data the API returns
- `dictionary-dump`: enables the dumping and pulling of remote dictionaries. Only for distributed PIC-SURE environments
- `dictionaryetl`: populates the Postgres database

If you want to learn more about the Dictionary API, you can start by visiting 
[the repo](https://github.com/hms-dbmi/picsure-dictionary/)
If you want to better understand the Dictionary Schema, you can explore it by connecting the database:

```shell
docker exec -ti dictionary-db dictionary picsure
set search_path to dict
# try \dt to show tables
```

## How do I load data into it?

There are two ways to load data into the Data Dictionary. You can either have the ETL pull concepts directly from HPDS,
or you can upload your own concepts, facets, and metadata via CSV.

### Direct from HPDS
Pulling directly from HPDS is less error-prone, but it doesn't allow you to customise the output. If you have important
metadata for your concepts that you want to search on, or you have custom display names, this may not be right for you.
To pull directly from HPDS, run the following jobs in order in Jenkins:

- PIC-SURE Dictionary-ETL Build (Builds tab)
  - git_hash: `*/main`
  - pipeline_build_id: `MANUAL_RUN`
- Load HPDS and Dictionary Data (Load Data tab)
  - Dataset: `Custom`
  - Dataset_Branch: `main`
  - HPDS_DATA_LOAD: `Single File (CSV)`
  - ✅ `Include_Genomic_Data`
  - ✅ `Clear_Dictionary_Database`
- Run Dictionary Weights (Load Data tab)
- Start PIC-SURE (Deployment tab)

### Build from CSV
Building from CSV allows you to add custom facets, change the names of concepts, and add metadata to enhance search. To
build from a CSV, run the following jobs in order in Jenkins:
- PIC-SURE Dictionary-ETL Build (Builds tab)
    - git_hash: `*/main`
    - pipeline_build_id: `MANUAL_RUN`
- Load Dictionary Data from Ingest CSVs
  - ✅ `CLEAR_DATABASE`
  - See notes below
- Run Dictionary Weights (Load Data tab)
- Start PIC-SURE (Deployment tab)

The `Load Dictionary Data from Ingest CSVs` job takes two CSV parameters: `datasets.csv` and `concepts.csv`.
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