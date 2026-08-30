# PIC-SURE All-in-one

Welcome to PIC-SURE! The PIC-SURE all-in-one package is a comprehensive tool developed by the Avillach Lab that offers a
seamless and efficient installation process for the PIC-SURE ecosystem. This integrated package includes the PIC-SURE
API, a powerful and flexible programming interface that enables easy access to a wide variety of clinical and genomic
data sources. Additionally, the tool offers a customizable web-based user interface (UI) that enables users to explore
and analyze complex datasets visually and interactively. The All-in-one also includes a Jenkins server that facilitates
the developing, updating, testing, and deploying of PIC-SURE systems, making it easier for developers to manage and
monitor the PIC-SURE ecosystem.

## Table of Contents
- [What is PIC-SURE?](#what-is-pic-sure)
- [Using the All-in-one](#using-the-all-in-one)
  - [Assumptions](#assumptions)
  - [Pre-deployment Preparation](#pre-deployment-preparation)
  - [Minimum System Requirements](#minimum-system-requirements)
  - [Operating System Requirements](#operating-system-requirements)
  - [Data Loading Requirements](#data-loading-requirements)
- [Steps to Install on a Fresh Server](#steps-to-install-on-a-fresh-server)
- [Additional Information](#additional-information)
- [Data Loading](#data-loading)
  - [Uploading HPDS-ETL Configuration](#uploading-hpds-etl-configuration)
  - [Manual Load HPDS](#manual-load-hpds)
  - [Data Dictionary](docs/dictionary.md)
  - [Copy HPDS data from Dev to Prod](#copy-hpds-data-from-dev-to-prod)
- [Updating Jenkins](#updating-jenkins)
- [Users](#users)
  - [Adding and Removing Users](#adding-and-removing-users)
- [MacOS - Apple Chip - M1,M2,M3,etc](#macos---apple-chip---m1m2m3etc)
  - [Setup Docker](#setup-docker)
  - [Setup All in One](#setup-all-in-one)

## What is PIC-SURE?

The Patient-centered Information Commons: Standard Unification of Research Elements (PIC-SURE) platform integrates
different layers of clinical and genomic data from diverse data sources, providing a multifaceted approach to biomedical
research.
The PIC-SURE platform was built on i2b2 (Informatics for Integrating Biology & the Bedside, a data model created for EHR
data), with an Apache 2.0 license (open source). PIC-SURE has been deployed in both FISMA Moderate ATO and HI-TRUST
environments.

The PIC-SURE platform provides both an intuitive graphical user interface (UI) and an application programming
interface (API) to meet different use cases and levels of experience with data manipulation. The PIC-SURE UI allows for
an investigator to search for variables of interest and to conduct feasibility queries. In this way, cohorts are built
in real-time and results can be retrieved for analysis.

See more at [pic-sure.org](https://pic-sure.org/about)

## Using the All-in-one

### Assumptions:

- This system will be maintained by someone with either a basic understanding of Docker or the will to learn and develop
  that understanding over time.

- The server can access the internet and your browser can access the server on ports `80`, `443`, `8080`.

- You have `sudo` privileges or root account access on the server.

### Pre-deployment Preparation:

- Ensure that you have a Google or G-Suite account. You will create an initial admin user tied to a Google account.

- You need an Auth0 Client Secret(`AUTH0_CLIENT_SECRET`), Client ID(`AUTH0_CLIENT_ID`), and an `AUTH0_TENANT` value for
  the Configure Auth0 Integration Jenkins job. Please contact us at http://avillachlabsupport.hms.harvard.edu and
  select "PIC-SURE All-in-one evaluation client credentials" for evaluation Client Credentials. If you are just
  evaluating PIC-SURE in a demo environment with the demo data that is included, you should use our demo credentials.
  You will want to use production credentials for environments that have controlled access data. Please specify which of
  these use-cases applies in your request. The Auth0 Applicatioon created to obtain this `CLIENT_ID` and `CLIENT_SECRET`
  must have OpenID-Connect Compliance turned off in the Auth0 settings.

- Before you can safely run the system in production you will need a SSL certificate, chain, and key that is compatible
  with Apache HTTPD. We bootstrap the PIC-SURE application with a self-signed cert. You can use that to evaluate the
  software, but be sure to switch to a legitimate cert before loading real patient data or exposing your server to a
  wider audience.

### Minimum System Requirements:

- 32 GB of RAM (We actually have servers running on as little as 8G, but those see very light loads)
- 8 cores
- 100 GB of hard drive space plus enough to hold your data

### Operating System Requirements:

We run PIC-SURE on AlmaLinux 8.x internally, but we aim to support more operating systems than that. If you have a *nix
operating system with docker installed on it, we should be able to help you get PIC-SURE running. You might see some
breakages in the bash scripts that run the initial configurations, but once you get things correctly configured, docker
should provide enough environment normalization to keep you running.

### Data Loading Requirements:

The resources required to load the data are determined based on the attributes of the data (number of patients, metadata
per patient, annotations, etc.) and the mechanism to load the data (CSV, RDS). <br>
Examples:

- If you are loading the small example datasets provided, such as 1000 patients from CDC NHANES and/or one chromosome
  from 1000 Genomes, then the minimum system requirements (8 vCPU, 32 GB ram) will be excessive.
- Boston Children’s Hospital requires `m5.4xlarge` ec2 (16 vCPU, 64 GB ram) and `HEAPSIZE=40,960` to load the following:
    - Clinical data for 2.9 million patients, with 112,267 variables and 874,530,503 observed facts in total loaded from
      an RDBMS using SQLLoader. Using the CSV loader may result in more resources being needed.
    - Genomic data for 4,000 patients, with the following annotation columns configured using the HPDS annotation
      pipeline to generate those annotations for 30,879,078 total variants.
        - Allele frequency in GNOMAD
        - Variant_severity from VEP
        - Variant_consequence from VEP
    - After the data is loaded, running the UI only requires m5.large ec2 (2 vCPU and 8gb ram). This can range depending
      on the size of the data.
    - AWS cost estimates based on Boston Children’s Hospital: $1,600 - $1,700 monthly costs for hosting the application and data (depending on the size of the data). $2,000 - $3,000 quarterly costs to map, process, and stage the data (depending on the size of the data)
    - To increase the HEAPSIZE, visit vi /var/jenkins_home/jobs/Load\ HPDS\ Data\ From\ RDBMS/config.xml Go down to the bottom of the file and you will see a "docker run" command.  In that command, look for the HEAPSIZE parameter, which can be changed depending on the size of the data. 

- If the resources required to load your data exceed the minimum system requirements, you can spin up an additional VM
  dedicated to loading the data. After you are finished loading the data, then that VM can be shut off.
- Additionally if your dataset is sufficiently large that loading it would cause disruptions in query processing for
  your production environment, it is advised to use a separate environment to conduct loading.
- Since a precise calculation to determine the resources required for loading data takes a prohibitive effort, a trial
  and error approach is the most practical way to determine what the loading resource environment is for any set of
  data.
- After loading the data into a development environment, you can transfer the javabin files from the development
  environment to a production environment, but copying the following files: 1.) encryption_key 2.) columnMeta.javabin
  3.) allObservationsStore.javabin. Then run the “Start PIC-SURE” Jenkins job, which will stop and start the containers.

## Steps to install on a fresh server:

Note: If you are doing this on a Mac, __please read this section first__: [MacOS Steps](#macos---apple-chip---m1m2m3etc)

1. Install Docker. This process can vary widely depending on your OS of choice, so we're not going to attempt to give
you exact instructions. If you're following the legacy install instructions, you can skip this.

2. Install Git
`sudo yum -y install git` or `sudo apt install git`, etc. 

3. Clone the PIC-SURE All-in-one repository
`git clone https://github.com/hms-dbmi/pic-sure-all-in-one`

4. Install the dependencies and build the Jenkins container

`cd pic-sure-all-in-one/initial-configuration`
Choose one of the following use cases:
- *Fully dockerized install.* Our current happy path.
`./install-dependencies-docker.sh /path/to/desired/config/dir/`
- *Legacy install.* I know what I'm doing. `sudo ./install-dependencies.sh`
- *Jenkins on https.* This is rare:
```shell
sudo ./install-dependencies-docker.sh /path/to/desired/config/dir/
./convert-cert.sh path/to/cert.key path/to/cert.crt password-for-created-key
```

5. Browse to Jenkins server
   Point your browser at your server's IP on port `8080`.

  For example, if your server has IP `10.109.190.146`, please browse to http://10.109.190.146:8080

  Note: Work with your local IT department to ensure that this port is not available to the public internet, but is
  accessible to you on your intranet or VPN. Anyone with access to this port can launch any application they wish on your
  server.

  Once you have logged into Jenkins and have set up your admin account, you need to update a few Jenkins
  system variables:

- `DOCKER_CONFIG_DIR`: `/path/to/config/dir` This is the path you passed to `install-dependencies-docker`
- `MYSQL_CONFIG_DIR`: `/path/to/mysql/cnf/dir` This is the path you passed to `install-dependencies-docker`
- `MYSQL_NETWORK`: `picsure` If you plan to switch to a remote database, this needs to be changed back to `host`

6. Run the Initial Configuration Pipeline job.
   In Jenkins, you will see 5 tabs: All, Configuration, Deployment, PIC-SURE Builds, Supporting Jobs. Click the
   Configuration tab, then click the button to the right of the Initial Configuration Pipeline job. It resembles a clock
   with a green triangle on it. See Additional Information below for how to connect to a remote SQL instance.

7. Provide the following information:

    - `AUTH0_CLIENT_ID`: This is the client_id of your Auth0 Application

    - `AUTH0_CLIENT_SECRET`: This is the client_secret of your Auth0 Application

    - `AUTH0_TENANT`: This is the first part of your Auth0 domain, for example if your domain is avillachlab.auth0.com you
      would enter avillachlab in this field.

    - `EMAIL`: This is the Google account that will be the initial admin user.

    - `MIGRATION_NAME`: This is the name of the migration that will be run. If you just want the default PIC-SURE behavior use `Baseline` from the repo: https://github.com/hms-dbmi/pic-sure-migrations or fork it and add your migration. If you are a GIC Institution, use `GIC-Institution`.

    - `RELEASE_CONTROL_REPOSITORY`: This is the repo that contains the build-spec.json file for your project. This file
      controls what code is built and deployed. If you just want the default PIC-SURE behavior use this
      repo : https://github.com/hms-dbmi/baseline-pic-sure-release-control

      All PIC-SURE Java services build from the single `hms-dbmi/pic-sure` monorepo: the build-spec's
      `PSA` entry pins one ref (branch, tag, or hash) that every service job builds from
      (`services/<name>` subdirectories). A release is one monorepo ref — the remaining separate
      entries are only for genuinely separate repos (`PSF` frontend, `PSM` migrations, `DICTIONARY_ETL`).

    - `ANALYTICS_ID`: This is the Google Analytics ID for your project. If you do not have one, you can leave this blank.

Note: Ensure none of these fields contain leading or trailing whitespace, the values must be exact. Once you have
entered the information,

8. Select an initial data set or provide your own using the "Custom" option.
    - If "Custom" is selected it is assumed you are providing your own data set via a single `allConcepts.csv` file. The
   provided `allConcepts.csv` file should be placed in the $DOCKER_CONFIG_DIR/hpds

9. Click the `Build` button.

Wait until all jobs complete. This may take several minutes. When nothing displays in the Build Queue or Build Executor
Status to the left of the page, all jobs will have completed.

10. Click the `All` tab to ensure nothing displays with a red dot next to it. If you see any red dots, please try
   restarting with a fresh install. If you consistently have one or more jobs fail and display red dots, please
   reach out to http://avillachlabsupport.hms.harvard.edu for help.

If all jobs have blue dots except the Check For Updates and Configure SSL Certificates job, which should be gray, you
can log into the UI for the first time.

11. Browse to the same domain or IP address as your Jenkins server without the `8080` port.

For example, if your server has IP `10.109.190.146`, you would browse to https://10.109.190.146

12. Log in using your Google account that you previously configured.

13. Once you have confirmed that you can access the PIC-SURE UI using your admin user, stop the jenkins server by
    running the following stop-jenkins.sh script:

sudo ./stop-jenkins.sh

## Additional Information:

- Any time you wish to update the system, please run the update-jenkins.sh script and then start the Jenkins server.
  This ensures the jenkins jobs and configurations are up to date. See [here](#updating-jenkins)

- Always stop Jenkins using the stop-jenkins.sh script when you are done to prevent unauthorized access as Jenkins
  effectively has root privileges on your server.

- To start or stop PIC-SURE use the "Start PIC-SURE" and "Stop PIC-SURE" jobs.

- The legacy JupyterHub jobs are archived under
  `initial-configuration/jenkins/jenkins-docker/archived-jobs` and are not installed into Jenkins.

- If you have an Apache HTTPD compatible certificate, chain, and key files for SSL configuration, navigate to the
  Configuration tab and run the Configure SSL Certificates job uploading your server.crt, server.chain, and server.key
  files using the Choose File buttons, then press the Build button. Once this completes, go to the Deployment tab and
  run the Deploy PIC-SURE job to restart your containers so the updated SSL configuration is used.

- As your project progresses you will run the "Check For Updates" job to pull and build the latest release of each
  component as the release control repository is updated. The job applies migrations, builds the release, and restarts
  PIC-SURE in the guarded order described below.

### Banner-capable release order

`Check For Updates` resolves one release-control commit, applies the database migrations from that release, and only
then builds and restarts the application. `Start PIC-SURE` recreates PSAMA, starts Operations, Query, and Gateway, and
waits for PSAMA health, Operations readiness, Query health, and a `RUNNING` Gateway deep system status before it starts
the public httpd/frontend container. PSAMA recreation is the deployment-wide authorization-cache refresh. AIO has no
global cache-eviction operation.

The update is fail closed. A migration or backend-health failure leaves the new frontend unpublished. During startup,
new banner management routes may remain unavailable until PSAMA has been recreated and the backend is healthy.

Use `Rollback PIC-SURE` only with an operator-reviewed `rollback-state.json`. Before running the job, stop httpd to
freeze banner management writes, retag the chosen exact frontend rollback image as
`hms-dbmi/pic-sure-frontend:LATEST`, and disable every Active or Scheduled targeted banner through the final Operations
management API. With public httpd stopped, the Jenkins container can still reach the existing Gateway on the internal
`picsure` Docker network at `http://gateway:8080`; send the normal authenticated management request through that path
and do not put its token in the state file. The state file attests those steps in this exact order and binds each exact
local image tag to the image ID inspected during operator review:

```json
{
  "schemaVersion": 1,
  "contractSourceCommit": "0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8",
  "contractSha256": "f8cb265d735b757872391e04fdcd5b999b785eaa427ca13f8f2eefd493715359",
  "completedPhases": [
    "FREEZE_BANNER_MANAGEMENT_WRITES",
    "ROLL_BACK_FRONTEND",
    "DISABLE_ACTIVE_AND_SCHEDULED_TARGETED_BANNERS_BEFORE_LEGACY_ACTIVE_FEED_BACKEND"
  ],
  "forwardSchemaRetained": true,
  "downMigrationRequested": false,
  "rollbackImages": {
    "frontend": "local/pic-sure-frontend:exact-rollback-tag",
    "psama": "local/psama:exact-rollback-tag",
    "operations": "local/pic-sure-operations-service:exact-rollback-tag",
    "query": "local/pic-sure-hpds-query-service:exact-rollback-tag",
    "gateway": "local/pic-sure-gateway:exact-rollback-tag"
  },
  "rollbackImageIds": {
    "frontend": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    "psama": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    "operations": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
    "query": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
    "gateway": "sha256:4444444444444444444444444444444444444444444444444444444444444444"
  }
}
```

The rollback job checks the shared contract and attestations, verifies every image tag still resolves to its attested
image ID, confirms that httpd is stopped and the frontend rollback tag is staged, then retags and starts the rolled-back
Operations, Query, and Gateway services before recreating PSAMA. It keeps httpd stopped, retaining the management-write
freeze while a backend below the targeted-feed boundary is active. Do not restart the public entrypoint until a
targeting-capable backend has been restored. Rollback always keeps the forward database schema; Flyway down-migrations
are prohibited.

- If you would like to connect to a remote database, then run the "Configure Remote MySQL Instance" Jenkins job.
    - You need to provide remote database connection information to "Configure Remote MySQL Instance" Jenkins job
        - Hostname, Port, Database username Database password.
    - Remote Database can be on premise (you have to manage the backups other Database Administration tasks) or cloud
      such as AWS, GCP, Azure (these are fully managed services for Relational Databases)
    - Cloud - AWS - RDS
    - Cloud - Azure - Azure SQL Database
    - Cloud - GCP - Cloud SQL

## Data Loading

### Uploading HPDS-ETL Configuration

To configure how your public dataset CSV files are interpreted and ingested by the HPDS-ETL process, use the Jenkins job **Upload HPDS-ETL Dataset Configuration**.

#### Purpose

This job uploads a `config.json` file that defines metadata for each input CSV file used during ETL. Each key in the JSON maps to a CSV filename (without extension), and the associated values specify how the file’s data should be handled.

#### Example `config.json`:

```json
{
  "nhanes": {
    "dataset_name": "Nhanes",
    "dataset_name_as_root_node": true
  },
  "1000_genomes": {
    "dataset_name": "1000Genomes",
    "dataset_name_as_root_node": true
  },
  "synthea": {
    "dataset_name": "Synthea",
    "dataset_name_as_root_node": true
  }
}
```

#### Configuration Details

- Each key corresponds to a CSV filename (e.g., `nhanesAllConcepts.csv`).
- `dataset_name`: Logical name of the dataset used in HPDS and the dictionary-db.
- `dataset_name_as_root_node`: If true, all concept paths within that CSV are rooted under `\dataset_name\`.

#### Example Behavior

For `nhanesAllConcepts.csv`:

- Key: `nhanesAllConcepts`
- Dataset Name: `Nhanes`
- Concept paths will be rooted under `\nhanes\`
- The dataset and its concepts will be visible in both HPDS and the PIC-SURE dictionary-db as part of the `Nhanes` dataset.

### Manual load HPDS
- Genotype Data
  Load: [https://github.com/hms-dbmi/pic-sure-all-in-one/blob/master/hpds_geno_load.md](https://github.com/hms-dbmi/pic-sure-all-in-one/blob/master/hpds_geno_load.md)
- Phenotypic Data
  Load: [https://github.com/hms-dbmi/pic-sure-hpds-phenotype-load-example](https://github.com/hms-dbmi/pic-sure-hpds-phenotype-load-example)

### Copy HPDS data from Dev to Prod
1. Backup `$DOCKER_CONFIG_DIR/hpds/hpds.env` file for any custom environment specific configurations.
2. Copy the entire `$DOCKER_CONFIG_DIR/hpds` folder from dev to production using rsync or other method. hpds is a large directory, you'll need a strategy to either backup/snapshot current production hpds data (if desired) or notify users that the site will be unstable if syncing the folder in place.
3. Replace or update new `$DOCKER_CONFIG_DIR/hpds/hpds.env` with data in backup from step 1.

## Updating Jenkins

We recommend you update jenkins in a regular cadence. We have a script you can run to make this easy. On an instance
that is already running, it updates both the jenkins jobs and and the jenkins version the the latest in the branch of
this repository you are using. **IMPORTANT NOTE:** This script does not migrate the jenkins admin/users. However, it
does migrate your initial configurations.  (Does not impact PIC-SURE users)

1. On the host machine navigate to the `pic-sure-all-in-one` directory.
1. Run `sudo ./update-jenkins.sh`
1. If jenkins is not running run the start script `sudo ./start-jenkins.sh`
1. Follow the jenkins set up steps again.

A backup of your jenkins home can be found here: `"$DOCKER_CONFIG_DIR"/jenkins_home_bak/`

### Migrating an existing WildFly environment

Updating Jenkins installs the mono-repo jobs, but it does not create the gateway,
operations-service, or query-service environment files required to replace a legacy
WildFly deployment. For an existing Docker all-in-one installation:

1. Back up `DOCKER_CONFIG_DIR`, including the `wildfly`, `httpd`, `logging`, and
   Jenkins configuration directories.
2. Update Jenkins using the instructions above.
3. Run **Migrate PIC-SURE Environment** and review its migration summary. The job
   copies required values such as the token-introspection token, PIC-SURE database
   password, and logging key into the new service env files; it also creates and
   synchronizes the new internal service tokens. WildFly remains running during this preparation step.
4. Run **PIC-SURE Database Migrations**, then run **PIC-SURE Pipeline**. The
   pipeline builds the mono-repo images and performs the Stop/Start restart that
   removes the legacy WildFly container and starts the gateway-era services.

The environment migration is idempotent and is safe to rerun after a partial
failure. It does not stop WildFly or archive the legacy configuration directory.
Do not run **Initial Configuration Pipeline** as an upgrade procedure for an
existing deployment.

## Users

### Adding and Removing Users

#### To add a user:

1. Click **Admin**.
2. Click **Add User**. A window appears.
3. **Adding User For** - If not Google, select the user's authentication service, also known as connection type.
4. **Email (required)** - Enter the new user's email address. Note: Duplicate email addresses can not be added to the
   same connection type.
5. **Roles** - Select one or more of the following roles for the user:

- **PIC-SURE Top Admin**: A super user who can create admins and manage user roles and privileges directly.
- **Admin**: A user who can assign roles and other privileges to users.
- **PIC-SURE User**: A normal user who can run any query including data export.
- **JupyterHub User**: A normal user who can access JupyterHub.

6. Click **Save user**.

#### To remove a user:

1. Click **Admin**.
2. Click the user you want to remove.
3. Click **Edit**.
4. **Roles** - Deselect any roles you applied to the user.
5. Click **Save user**.

To deactivate a user:

1. Click **Admin**.
2. Click the user you want to remove.
3. Click **Deactivate**.

**Note:** When you deactivate a user, the user is gone forever and their email address cannot be used for a new user. To
keep a user in the system without giving them access to PIC-SURE, follow the "To remove a user" procedure.

## MacOS - Apple Chip - M1,M2,M3,etc
### Setup Docker
- Navigate to your docker desktop.
- Go to your **Settings**
- Under General -> Virtual Machine Options—Select the following Options:
  >- Apple Virtualization Framework.
  >- Use Rosetta for x86_64/amd64 emulation on Apple Silicon
  >- VirtioFS
- Under resources -> File Sharing -> Virtual file shares
  >- Provide the path you intend to install the local all in one configuration. This is the same path specified as the first argument passed to the `install-dependencies-docker.sh`

### Setup All in One
- `cd pic-sure-all-in-one/initial-configuration`
- *Fully dockerized install.* Our current happy path.
```shell
./install-dependencies-docker.sh /path/to/desired/config/dir/ && source ~/.bashrc
```
- Continue by following the [Steps to Install on a Fresh Server](#steps-to-install-on-a-fresh-server) from step 5 onwards.
