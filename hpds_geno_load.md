Below are the steps to populate genomic data in HPDS.

Note: Before you begin, please update the PIC-SURE All-In-One Jenkins Server by running `git pull` then `./update-jenkins.sh` in the pic-sure-all-in-one directory on your server. This will build a new Jenkins server image and restart Jenkins with the latest jobs and plugins.

### Populate /usr/local/docker-config/vcf-load with your source data.

In the $DOCKER_CONFIG_DIR/vcf-load/ directory, please include the following files:
- vcfIndex.tsv: a file that describes the VCF file(s) to be loaded.
  Note: For more information about the vcfIndex.tsv format, see [https://github.com/hms-dbmi/pic-sure-hpds-genotype-load-example#loading-your-vcf-data-into-hpds](https://github.com/hms-dbmi/pic-sure-hpds-genotype-load-example#loading-your-vcf-data-into-hpds). You can have multiple vcfIndex.tsv files for different groups of patients, as long as they do not overlap.
- the VCF file(s) that will be read and converted to the hpds format.

### Build Genomic Data

Run the "Load VCF Data" Jenkins job. This will create genomic data in the HPDS format but will not update HPDS.

### Upload Data into HPDS 

Run the "Load Staged Genomic Data" Jenkins job. This will move any genomic data you have built into the HPDS directory to be used next time the application restarts.
