Below are the steps to populate genomic data in HPDS.

Note: Before you begin, please update the PIC-SURE All-In-One Jenkins Server by running `git pull` then `./update-jenkins.sh` in the pic-sure-all-in-one directory on your server. This will build a new Jenkins server image and restart Jenkins with the latest jobs and plugins.

### Populate `$DOCKER_CONFIG_DIR/vcfLoad` with your source data.

In `$DOCKER_CONFIG_DIR/vcfLoad`  directory, please include the following files:
- vcfIndex.tsv: a file that describes the VCF file(s) to be loaded. 
  Note: For more information about the vcfIndex.tsv format, see [https://github.com/hms-dbmi/pic-sure-hpds-genotype-load-example#loading-your-vcf-data-into-hpds](https://github.com/hms-dbmi/pic-sure-hpds-genotype-load-example#loading-your-vcf-data-into-hpds).
- vcfLoad/: a directory containing the vcf file(s) that will be read and converted to the hpds format.

### Upload Data into HPDS 

Load Genomic Data from VCF using the Jenkins job - "Load Genomic Data". To do this, access jenkins on port 8080. 

This job loads HPDS data from `$DOCKER_CONFIG_DIR/vcfLoad` and may take several minutes.

### Moving genomic data between environments

To copy data between environments (ex: moving development data to production after testing it):
- Copy all files from `$DOCKER_CONFIG_DIR/hpds/all` from the source environment to the target environment