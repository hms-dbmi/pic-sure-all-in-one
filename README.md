# PIC-SURE All-in-one

Welcome to PIC-SURE! The PIC-SURE all-in-one package is a comprehensive tool developed by the Avillach Lab that offers a seamless and efficient installation process for the PIC-SURE ecosystem. This integrated package includes the PIC-SURE API, a powerful and flexible programming interface that enables easy access to a wide variety of clinical and genomic data sources. Additionally, the tool offers a customizable web-based user interface (UI) that enables users to explore and analyze complex datasets visually and interactively. The All-in-one also includes a Jenkins server that facilitates the developing, updating, testing, and deploying of PIC-SURE systems, making it easier for developers to manage and monitor the PIC-SURE ecosystem.

## What is PIC-SURE?

The Patient-centered Information Commons: Standard Unification of Research Elements (PIC-SURE) platform integrates different layers of clinical and genomic data from diverse data sources, providing a multifaceted approach to biomedical research.
The PIC-SURE platform was built on i2b2 (Informatics for Integrating Biology & the Bedside, a data model created for EHR data), with an Apache 2.0 license (open source). PIC-SURE has been deployed in both FISMA Moderate ATO and HI-TRUST environments.

The PIC-SURE platform provides both an intuitive graphical user interface (UI) and an application programming interface (API) to meet different use cases and levels of experience with data manipulation. The PIC-SURE UI allows for an investigator to search for variables of interest and to conduct feasibility queries. In this way, cohorts are built in real-time and results can be retrieved for analysis.

See more at [pic-sure.org](https://pic-sure.org/about)

## Using the All-in-one

Assumptions:

- This system will be maintained by someone with either a basic understanding of Docker or the will to learn and develop that understanding over time.

- The server can access the internet and your browser can access the server on ports `80`, `443`, `8080`.

- You have `sudo` privileges or root account access on the server.

Preparing to deploy:

- You will create an initial admin user tied to a Google account. Decide which google account you want to use.

- You need an Auth0 Client Secret(`AUTH0_CLIENT_SECRET`), Client ID(`AUTH0_CLIENT_ID`), and an `AUTH0_TENANT` value for the Configure Auth0 Integration Jenkins job. Please contact us at http://avillachlabsupport.hms.harvard.edu and select "PIC-SURE All-in-one evaluation client credentials" for evaluation Client Credentials. If you are just evaluating PIC-SURE in a demo environment with the demo data that is included, you should use our demo credentials. You will want to use production credentials for environments that have controlled access data. Please specify which of these use-cases applies in your request. The Auth0 Applicatioon created to obtain this `CLIENT_ID` and `CLIENT_SECRET` must have OpenID-Connect Compliance turned off in the Auth0 settings.

- Before you can safely run the system in production you will need a SSL certificate, chain, and key that is compatible with Apache HTTPD. If you are unable to obtain secure SSL certs and key, and are taking steps to keep your system from being accessible to the public internet you can choose to accept the risk that someone may steal your data or hijack your server by using the development certs and key that come installed by default. -- *USE THE DEFAULT CERTS AND KEY AT YOUR OWN RISK* --


Minimum System Requirements:

- 32 GB of RAM
- 8 cores
- 100 GB of hard drive space plus enough to hold your data
- Only Centos 7 is supported for operating systems

Data Loading Requirements: <p>
The resources required to load the data are determined based on the attributes of the data (number of patients, metadata per patient, annotations, etc.) and the mechanism to load the data (CSV, RDS). <br>
Examples:
- If you are loading the small example datasets provided, such as 1000 patients from CDC NHANES and/or one chromosome from 1000 Genomes, then the minimum system requirements (8 vCPU, 32 GB ram) will be excessive. 
- Boston Children’s Hospital requires `m5.4xlarge` ec2 (16 vCPU, 64 GB ram) and `HEAPSIZE=40,960` to load the following: 
    - Clinical data for 2.9 million patients, with 112,267 variables and 874,530,503 observed facts in total loaded from an RDBMS using SQLLoader. Using the CSV loader may result in more resources being needed. 
    - Genomic data for 4,000 patients, with the following annotation columns configured using the HPDS annotation pipeline to generate those annotations for 30,879,078 total variants.
        - Allele frequency in GNOMAD
        - Variant_severity from VEP
        - Variant_consequence from VEP
    - After the data is loaded, running the UI only requires m5.large ec2 (2 vCPU and 8gb ram). This can range depending on the size of the data. 

- If the resources required to load your data exceed the minimum system requirements, you can spin up an additional VM dedicated to loading the data. After you are finished loading the data, then that VM can be shut off. 
- Additionally if your dataset is sufficiently large that loading it would cause disruptions in query processing for your production environment, it is advised to use a separate environment to conduct loading.
- Since a precise calculation to determine the resources required for loading data takes a prohibitive effort, a trial and error approach is the most practical way to determine what the loading resource environment is for any set of data.
- After loading the data into a development environment, you can transfer the javabin files from the development environment to a production environment, but copying the following files: 1.) encryption_key 2.) columnMeta.javabin 3.) allObservationsStore.javabin. Then run the “Start PIC-SURE” Jenkins job, which will stop and start the containers.


## Steps to install on a fresh Centos 7 installation:

1. Install Git

`sudo yum -y install git`

2. Clone the PIC-SURE All-in-one repository

`git clone https://github.com/hms-dbmi/pic-sure-all-in-one`

3. Install the dependencies and build the Jenkins container

`cd pic-sure-all-in-one/initial-configuration`

`sudo ./install-dependencies.sh`

If you need Jenkins to use https, you can configure that by passing a key, and cert to the 
install script:

`sudo ./install-dependencies.sh path/to/cert.key path/to/cert.crt`

4. Browse to Jenkins server
Point your browser at your server's IP on port `8080`. 

For example, if your server has IP `10.109.190.146`, please browse to http://10.109.190.146:8080

Note: Work with your local IT department to ensure that this port is not available to the public internet, but is accessible to you on your intranet or VPN. Anyone with access to this port can launch any application they wish on your server.

5. Run the Initial Configuration Pipeline job. 
In Jenkins you will see 5 tabs: All, Configuration, Deployment, PIC-SURE Builds, Supporting Jobs. Click the Configuration tab, then click the button to the right of the Initial Configuration Pipeline job. It resembles a clock with a green triangle on it. See Additional Information below for how to connect to a remote SQL instance. 

6. Provide the following information:

    - AUTH0_CLIENT_ID: This is the client_id of your Auth0 Application

    - AUTH0_CLIENT_SECRET: This is the client_secret of your Auth0 Application

    - AUTH0_TENANT: This is the first part of your Auth0 domain, for example if your domain is avillachlab.auth0.com you would   enter avillachlab in this field.

    - EMAIL: This is the Google account that will be the initial admin user.

    - PROJECT_SPECIFIC_OVERRIDE_REPOSITORY: This is the repo that contains the project specific overrides for your project. If you just want the default PIC-SURE behavior use this repo : https://github.com/hms-dbmi/baseline-pic-sure

    - RELEASE_CONTROL_REPOSITORY: This is the repo that contains the build-spec.json file for your project. This file controls what code is built and deployed. If you just want the default PIC-SURE behavior use this repo : https://github.com/hms-dbmi/baseline-pic-sure-release-control

    - ANALYTICS_ID: This is the Google Analytics ID for your project. If you do not have one, you can leave this blank.
    
Note: Ensure none of these fields contain leading or trailing whitespace, the values must be exact. Once you have entered the information,

7. Click the "Build" button.

Wait until all jobs complete. This may take several minutes. When nothing displays in the Build Queue or Build Executor Status to the left of the page, all jobs will have completed.

8. Click the All tab to ensure nothing displays with a red dot next to it. If you see any red dots, please try restarting with a fresh Centos7 install. If you consistently have one or more jobs fail and display red dots, please reach out to http://avillachlabsupport.hms.harvard.edu for help.

If all jobs have blue dots except the Check For Updates and Configure SSL Certificates job, which should be gray, you can log into the UI for the first time. 

9. Browse to the same domain or IP address as your Jenkins server without the `8080` port.

For example, if your server has IP `10.109.190.146`, you would browse to https://10.109.190.146

10. Log in using your Google account that you previously configured.

11. Once you have confirmed that you can access the PIC-SURE UI using your admin user, stop the jenkins server by runnning the following stop-jenkins.sh script:

sudo ./stop-jenkins.sh


## Additional Information:

- Any time you wish to update the system, please run the update-jenkins.sh script and then start the Jenkins server. This ensures the jenkins jobs and configurations are up to date. See [here](#updating-jenkins)

- Always stop Jenkins using the stop-jenkins.sh script when you are done to prevent unauthorized access as Jenkins effectively has root privileges on your server.

- To start or stop PIC-SURE use the "Start PIC-SURE" and "Stop PIC-SURE" jobs.

- To start or stop JupyterHub use the "Start JupyterHub" and "Stop JupyterHub" jobs. The Start JupyterHub job asks you to set a password. Currently this password is shared by all JupyterHub users, we are working to integrate JupyterHub with the PIC-SURE Auth Micro-App so that users can log in using the same credentials they use to access PIC-SURE UI. To access JupyterHub browse to your server ip address on the path /jupyterhub

For example, if your server has IP `10.109.190.146`, browse to https://10.109.190.146/jupyterhub

- If you have an Apache HTTPD compatible certificate, chain, and key files for SSL configuration, navigate to the Configuration tab and run the Configure SSL Certificates job uploading your server.crt, server.chain, and server.key files using the Choose File buttons, then press the Build button. Once this completes, go to the Deployment tab and run the Deploy PIC-SURE job to restart your containers so the updated SSL configuration is used.

- As your project progresses you will run the "Check For Updates" job to pull and build the latest release of each component as the release control repository is updated. To deploy the latest updates after "Check For Updates" is run, execute the Start PIC-SURE job.

- If you would like to connect to a remote database, then run the "Configure Remote MySQL Instance" Jenkins job.
    - You need to provide remote database connection information to "Configure Remote MySQL Instance" Jenkins job
        - Hostname, Port, Database username Database password.
    - Remote Database can be on premise (you have to manage the backups other Database Administration tasks) or cloud such as AWS, GCP, Azure (these are fully managed services for Relational Databases)
    - Cloud - AWS - RDS 
    - Cloud - Azure - Azure SQL Database
    - Cloud - GCP - Cloud SQL
  

## Data Loading into HPDS
- Genotype Data Load: [https://github.com/hms-dbmi/pic-sure-all-in-one/blob/master/hpds_geno_load.md](https://github.com/hms-dbmi/pic-sure-all-in-one/blob/master/hpds_geno_load.md)
- Phenotypic Data Load: [https://github.com/hms-dbmi/pic-sure-hpds-phenotype-load-example](https://github.com/hms-dbmi/pic-sure-hpds-phenotype-load-example)

## Updating Jenkins

We recommend you update jenkins in a regular cadence. We have a script you can run to make this easy. On an instance that is already running, it updates both the jenkins jobs and and the jenkins version the the latest in the branch of this repository you are using. **IMPORTANT NOTE:** This script does not migrate the jenkins admin/users. However, it does migrate your initial configurations.  (Does not impact PIC-SURE users)

1. On the host machine navigate to the `pic-sure-all-in-one` directory.
1. Run `sudo ./update-jenkins.sh`
1. If jenkins is not running run the start script `sudo ./start-jenkins.sh`
1. Follow the jenkins set up steps again.
    
A backup of your jenkins home can be found here: `/var/jenkins_home_bak/`
    
## Users
### Adding and Removing Users
#### To add a user:
1. Click **Admin**.
2. Click **Add User**. A window appears.
3. **Adding User For** - If not Google, select the user's authentication service, also known as connection type. 
4. **Email (required)** - Enter the new user's email address. Note: Duplicate email addresses can not be added to the same connection type. 
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

**Note:** When you deactivate a user, the user is gone forever and their email address cannot be used for a new user. To keep a user in the system without giving them access to PIC-SURE, follow the "To remove a user" procedure.

