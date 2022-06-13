# **pic-sure-all-in-one**
____________________________________________________________________________________
**Prerequisites to setup pic-sure-all-in-one**

- EC2 instance need to have access to internet to download yum packages, docker images, maven packages
- EC2 should be able to access MariaDB running in RDS
    - Development
        - By default a MariaDB is running in a ccontainer
    - Production
        - Using the Configure Remote MySQL instance Jenkins job to point to Remote Database (either running on a different host or in RDS)
- Need to run the script as root

    **We need Root access on the EC2 instance for following reasons**

    - To install yum updates
    - To Install and enable systems services for MariaDB, Jenkins.service, Firewalld
    - To create log directories, volume mounts
    - To configure pic-sure-specific configurations
    - To make firewall-cmd changes apply
    - Firewall Port need to be opened
	- We Need Port 8080/TCP to be opened to access jenkin
- Redhat subscription needs to be updated.
    - Dev
    - Prod
- Download **jboss-eap-7.4.0.zip** from redhat portal
	1) Navigate to redhat developer portal <https://developers.redhat.com/>
	2) Login with redhat subscription credentials
	3) From the top menu bar select "Products" menu
	4) Click on jboss enterprise application platform, it will redirects to product overview page <https://developers.redhat.com/products/eap/overview>
	5) Click on download, it will navigate to product download page <https://developers.redhat.com/products/eap/download>
	6) Download jboss EAP 7.4 zip archive file

- Create home directory for stack /usr/local/docker-config
    - mkdir -p  /usr/local/docker-config
- Minimum system requirements:
    - 32 GB of RAM
    - 8 core
    - 100 GB of hard drive space plus enough to hold your data
	- RHEL 8.4 or RHEL 8.6 operating system

**Preparing to deploy:**

- You will create an initial admin user tied to a google account. Decide which google account you want to use.
- You need an Auth0 Client Secret(AUTH0_CLIENT_SECRET), Client ID(AUTH0_CLIENT_ID), and an AUTH0_TENANT value for the Configure Auth0 Integration Jenkins job. Please contact us at [http://avillachlabsupport.hms.harvard.edu](http://avillachlabsupport.hms.harvard.edu/) and select "PIC-SURE All-in-one evaluation client credentials" for evaluation Client Credentials. 
- If you are just evaluating PIC-SURE in a demo environment with the demo data that is included, you should use our demo credentials. You will want to use production credentials for environments that have controlled access data. Please specify which of these use-cases applies in your request. The Auth0 Application created to obtain this CLIENT_ID and CLIENT_SECRET must have OpenID-Connect Compliance turned off in the Auth0 settings.
-   Before you can safely run the system in production you will need a SSL certificate, chain, and key that is compatible with Apache HTTPD. If you are unable to obtain secure SSL certs and key, and are taking steps to keep your system from being accessible to the public internet you can choose to accept the risk that someone may steal your data or hijack your server by using the development certs and key that come installed by default. -- *USE THE DEFAULT CERTS AND KEY AT YOUR OWN RISK* --

**Steps to install on a fresh RHEL 8.4**

  1. Install git
   	  - yum -y install git (if not already installed)
  2. Clone the pic-sure redhat branch All-in-one repository
      - cd /usr/local/docker-config
   	  - git clone -b feature/redhat https://github.com/hms-dbmi/pic-sure-all-in-one
  3. Navigate to pic-sure-all-in-one project directory to access startup
	    - cd pic-sure-all-in-one/initial-configuration
  4. Download and copy **jboss-eap-7.4.0.zip** file from local to ec2 instance
      - On my local under downloads folder i have Jboss-eap-7.4.0.zip redhat file, scp the file to ec2 instance pics-sure-all-in-one config location        “**/usr/local/docker-config/pic-sure-all-in-one/initial-configuration/config/wildfly”**  
  **Example:**
     - sudo scp -i your-ec2-instance.pem \~/Downloads/jboss-eap-7.4.0.zip [ec2-user@your-ec2-instance.amazon.com](mailto:ec2-  user@ec2instance.amazon.com):/usr/local/docker-config/pic-sure-all-in-one/initial-configuration/config/wildfly
  5. Run The redhat install dependencies script, This script will install all necessary dependency to run project, MariaDB server, jenkins server, copy the necessary file changes to respective mount locations, create necessary directories
  		- **./redhat-install-dependencies.sh**
   	
   **Note:** Please check the console output while the script is executing, MariaDB is started and jenkins container started. If everything looks good you can check jenkins systemd service is started.
   
  6. Browse to jenkins server
	- Point your browser at your server's IP on port 8080. Or localhost port 8080
	- For example, to access jenkins on **http://localhost:8080**  
 	if your server has IP 10.89.144.12, please browse to **[http://10.89.144.12:8080]**(http://192.168.57.3:8080)

**Note**: Work with your local IT department to ensure that this port is not available to the public internet, but is accessible to you on your intranet or VPN. anyone with access to this port can launch any application they wish on your server.

  7. In Jenkins you will see 5 tabs: All, Configuration, Deployment, PIC-SURE Builds, Supporting Jobs
    Click the Configuration tab, then click the button to the right of the Initial Configuration Pipeline job. It resembles a clock with a green triangle on it.
    Provide the following information:

	  1. AUTH0_CLIENT_ID: This is the client_id of your auth0 application
	  2. AUTH0_CLIENT_SECRET: This is the client_secret of your auth0 application
	  3  AUTH0_TENANT: This is the first part of your auth0 domain, for example if your domain is avillachlab.auth0.com you would enter avillachlab in this field
	  4. EMAIL: This is the google account that will be the initial admin user.
	  5. PROJECT_SPECIFIC_OVERRIDE_REPOSITORY: This is the repo that contains the project specific overrides for your project. If you just want the default PIC-SURE behavior use this repo : <https://github.com/hms-dbmi/baseline-pic-sure>
	  6. RELEASE_CONTROL_REPOSITORY: This is the repo that contains the build-spec.json file for your project. This file controls what code is built and deployed. If you just want the default PIC-SURE behavior use this repo : <https://github.com/hms-dbmi/baseline-pic-sure-release-control>
    Note: Ensure none of these fields contain leading or trailing whitespace, the values must be exact. Once you have entered the information,
	  7. Click the "Build" button.
	  8. Wait until all jobs complete. This may take several minutes. When nothing displays in the "Build Queue" or "Build Executor Status" to the left of the page, all jobs will have completed.
    
8. Click the All tab to ensure nothing displays with a red dot next to it. If you see any red dots, please try restarting with a fresh Redhat 8.4 install. If you consistently have one or more jobs fail and display red dots, please reach out to [http://avillachlabsupport.hms.harvard.edu](http://avillachlabsupport.hms.harvard.edu/) for help.
    If all jobs have blue dots except the "Check For Updates" and "Configure SSL Certificates job", which should be gray, you can log into the UI for the first time.
	- To access pic-sure application locally from browser Add an alias/route for picsure.local to map your host ip in /etc/hosts file
    On the host as root/admin user
      **example** : 127.0.0.1 is my local host and picsure.local is url which accessed from browser
      **/etc/hosts**
	    127.0.0.1 picsure.local
10. Navigate to browser and enter https://picsure.local
11. Log in using your google account that you previously configured
12. Once you have confirmed that you can access the PIC-SURE UI using your admin user, stop the jenkins server by using jenkins systemd service
  	  **sudo systemctl stop jenkins**
13. Jenkins service is managed by systemd service on host, jenkins is running on port 8080
-  **To start jenkins service**
    - systemctl start jenkins or sudo systemctl start jenkins or
    - cd /usr/local/docker-config/pic-sure-all-in-one/initial-configuration
    - ./start-local-jenkins.sh
- **To stop jenkins service**
    - systemctl stop jenkins or sudo systemctl stop jenkins or
    - cd /usr/local/docker-config/pic-sure-all-in-one/initial-configuration
    - ./stop-local-jenkins.sh
- **To check the state of jenkins**
   - systemctl status jenkins or sudo systemctl status jenkins 
- **Jenkins log file location**
   - /var/log/jenkins/jenkins.log   
14. Start and Stop Pic-sure application from host
- **To stop pic-sure application**
  - cd /usr/local/docker-config/pic-sure-all-in-one
  - ./stop-picsure-redhat.sh
- **To start pic-sure application**
   - cd /usr/local/docker-config/pic-sure-all-in-one
   - ./start-picsure-redhat.sh

# **Additional Information:**
- Always stop jenkins using the stop-local-jenkins.sh script when you are done to prevent unauthorized access as jenkins effectively has root privileges on your server.
- To start or stop PIC-SURE use the "Start PIC-SURE" and "Stop PIC-SURE" jobs.\
- To start or stop JupyterHub use the "Start JupyterHub" and "Stop JupyterHub" jobs. The Start JupyterHub job asks you to set a password. Currently this password is shared by all JupyterHub users, we are working to integrate JupyterHub with the PIC-SURE Auth Micro-App so that users can log in using the same credentials they use to access PIC-SURE UI. To access JupyterHub browse to your server ip address on the path /jupyterhub

	For example, if your server has IP 10.109.190.146, browse to <https://10.109.190.146/jupyterhub>

- If you have an Apache HTTPD compatible certificate, chain, and key files for SSL configuration, navigate to the Configuration tab and run the Configure SSL Certificates job uploading your server.crt, server.chain, and server.key files using the Choose File buttons, then press the Build button. Once this completes, go to the Deployment tab and run the Deploy PIC-SURE job to restart your containers so the updated SSL configuration is used.
- As your project progresses you will run the Check For Updates job to pull and build the latest release of each component as the release control repository is updated. To deploy the latest updates after Check For Updates is run, execute the Start PIC-SURE job.

# **Data Loading into HPDS**
- Genotype Data Load: <https://github.com/hms-dbmi/pic-sure-all-in-one/blob/master/hpds_geno_load.md>
- Phenotypic Data Load: <https://github.com/hms-dbmi/pic-sure-hpds-phenotype-load-example>

# **Users**

## **Adding and Removing Users**

To add a user:

  1. Click **Admin**.
  2. Click **Add User**. A window appears.
  3. **Adding User For** - If not Google, select the user's authentication service, also known as connection type.
  4. **Email (required)** - Enter the new user's email address. Note: Duplicate email addresses can not be added to the same connection type.
  5. **Roles** - Select one or more of the following roles for the user:
  6. **PIC-SURE Top Admin**: A super user who can create admins and manage user roles and privileges directly.
  7. **Admin**: A user who can assign roles and other privileges to users.
  8. **PIC-SURE User**: A normal user who can run any query including data export.
  9. **JupyterHub User**: A normal user who can access JupyterHub.
  10. Click **Save user**.

**To remove a user:**
  1. Click **Admin**.
  2. Click the user you want to remove.
  3. Click **Edit**.
  4. **Roles** - Deselect any roles you applied to the user.
  5. Click **Save user**.

**To deactivate a user:**
  1. Click Admin.
  2. Click the user you want to remove.
  3. Click **Deactivate**.
  
**Note:** When you deactivate a user, the user is gone forever and their email address cannot be used for a new user. To keep a user in the system without giving them access to PIC-SURE, follow the "To remove a user" procedure.
