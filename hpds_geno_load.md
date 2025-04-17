Below are the steps to populate genomic data in HPDS.

Note: Before you begin, please update the PIC-SURE All-In-One Jenkins Server by running `git pull` then `./update-jenkins.sh` in the pic-sure-all-in-one directory on your server. This will build a new Jenkins server image and restart Jenkins with the latest jobs and plugins.

## Populate /usr/local/docker-config/vcf-load with your source data.

In the $DOCKER_CONFIG_DIR/vcf-load/ directory, please include the following files:
- vcfIndex.tsv: a file that describes the VCF file(s) to be loaded.
  Note: For more information about the vcfIndex.tsv format, see [VCF Index Files](#vcf-index-files). You can have multiple vcfIndex.tsv files for different groups of patients, as long as they do not overlap.
- the VCF file(s) that will be read and converted to the hpds format.
  Note: For more information on VCF files, see [Steps for preparing VCF files](https://github.com/bch-gnome/hpds_annotation#recommended-steps-for-preparing-vcf-files)

## Build Genomic Data

Run the "Load VCF Data" Jenkins job. This will create genomic data in the HPDS format but will not update HPDS.

## Upload Data into HPDS 

Run the "Load Staged Genomic Data" Jenkins job. This will move any genomic data you have built into the HPDS directory to be used next time the application restarts.


## VCF Index Files

Before loading your VCF file(s), at least one VCF index file must be created. The `vcfIndex.tsv` must be a tab separated flat file with 1 line per VCF file you intend to load. See sample file at `hpds/vcfIndex_sample.tsv`

The columns in this file are:

**`filename	chromosome	annotated	gzip	sample_ids	patient_ids	sample_relationship	related_sample_ids`**

- **`filename`** - The name of a VCF file. Please specify an absolute path and ensure it is reachable from inside the docker container running the VCF loader job.

- **`chromosome`** - The name or number of the chromosome in the file. `2, chr2, X, chrX` are all valid values. `ALL` as a value for this column is deprecated. Alternate contigs (ex: `chr19_KI270866v1_alt`) do not need their own VCF file

- **`annotated`** - binary flag set to 0 if you don't want to load annotations and to 1 if you do. Loading annotations is recommended.

- **`gzip`** - binary flag set to 0 if the file is uncompressed, 1 if it is GZIP compressed, bgzip is supported as it is GZIP, but no other compression algorithms are currently supported.

- **`sample_ids`** - A comma separated list of the sample ids in your VCF file. These are typically in the last line of the VCF header, but we need them here too to be safe.

- **`patient_ids`** - A comma separated list of the numeric(integer) patient ids that HPDS should use to link this to any phenotype data in the environment. This is required even if you don't have phenotype data because we still need patient ids that are integers.

- **`sample_relationship`** - not currently used, but in the future it would be the relationship of this sample to another corresponding sample in related_sample_ids

- **`related_sample_ids`** - not currently used

>> **NOTE**: The order of the Sample IDs in the vcfIndex file does not need to be the same as the vcf file.


## Additional VCF information

### Imputing Variant Calls

If different patients are loaded from different VCF files, any variants in one file but not in the other will be imputed as `0/1` NOT `./1` for any patients not explicitly mapped to a variant

### Multi-allelic variants

Multi-allelic variants have to be split into multiple rows. So if you have:

`1	1111111	.	A	T,C	100	PASS	.	GT	1/2`

You have to split it to:

```
1	1111111	.	A	T	100	PASS	.	GT	0/1
1	1111111	.	A	C	100	PASS	.	GT	0/1
```


### There is no support currently for flag-based INFO columns. 

One approach that works well is to map all of the flag values for a row into a new INFO column called FLAGS and put all values for the VCF row into that column like so:

`1	1111111	.	A	T	100	PASS	MULTIALLELIC;SYNONYMOUS;	GT	0/1`

Is changed to:

`1	1111111	.	A	T	100	PASS	FLAGS=MULTIALLELIC,SYNONYMOUS;	GT	0/1`

### Phased records 
Phased records are coerced into unphased by the loader. This means `1|0` and `0|1` both become `0/1` after they are loaded.