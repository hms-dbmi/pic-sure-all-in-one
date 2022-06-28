# **pic-sure-all-in-one**
____________________________________________________________________________________
**Prerequisites to setup pic-sure-all-in-one**
- Minimum system requirements for EC2 instance:
    - 32 GB of RAM
    - 8 core
    - 100 GB of hard drive space enough to hold your data
    - RHEL 8.4 or RHEL 8.6 operating system
- EC2 instance need to have access to internet to download yum packages, docker images, maven packages
- EC2 instance Need root access to run the redhat-install-dependencies.sh script for following reasons
    - To install yum updates
    - To Install and enable systemd services for MariaDB, jenkins.service, firewalld
    - To create log directories, volume mounts
    - To configure pic-sure-specific configurations
    - To apply firewall-cmd changes
    - Firewall port need to be opened
    - Need port 8080/TCP to be opened to access jenkins
- EC2 instance need to have Redhat subscription.
    - Dev
    - Prod
- EC2 instance should be able to access MariaDB running in RDS
    - Development
        - By default a MariaDB is running in a ccontainer
    - Production
        - Using the "Configure Remote MySQL instance" Jenkins job to point to remote ratabase (either running on a different host or in RDS)
- Download **jboss-eap-7.4.0.zip** from redhat portal
	1) Navigate to redhat developer portal <https://developers.redhat.com/>
	2) Login with redhat subscription credentials
	3) From the top menu bar select "Products" menu
	4) Click on jboss enterprise application platform, it will redirects to product overview page <https://developers.redhat.com/products/eap/overview>
	5) Click on download, it will navigate to product download page <https://developers.redhat.com/products/eap/download>
	6) Download jboss eap 7.4 zip archive file
- Create home directory for stack /usr/local/docker-config
        - mkdir -p  /usr/local/docker-config
- Install aws cli on EC2 instance
        - yum install -y awscli
- List of git branches modified or used for feature/redhat branch (Don't clone)
	- Pic-sure-all-in-one feature/redhat core branch: 
		- https://github.com/hms-dbmi/pic-sure-all-in-one (feature/redhat)
	- Pic-sure-hpds-ui  feature/redhat httpd base image base repo
		- https://github.com/hms-dbmi/pic-sure-hpds-ui.git (feature/redhat)
	- Pic-sure-hpds-ui feature/redhat hpds image git repo
		- https://github.com/hms-dbmi/pic-sure-hpds.git (feature/redhat)
	- Pic-sure baseline release control  which will have git hashes specific to feature/redhat branches
		- https://github.com/hms-dbmi/baseline-pic-sure-release-control (feature/redhat)

**Preparing to deploy:**

- You will create an initial admin user tied to a google account. Decide which google account you want to use.
- You need an Auth0 Client Secret(AUTH0_CLIENT_SECRET), Client ID(AUTH0_CLIENT_ID), and an AUTH0_TENANT value for the Configure Auth0 Integration Jenkins job. Please contact us at [http://avillachlabsupport.hms.harvard.edu](http://avillachlabsupport.hms.harvard.edu/) and select "PIC-SURE All-in-one evaluation client credentials" for evaluation Client Credentials. 
- If you are just evaluating PIC-SURE in a demo environment with the demo data that is included, you should use our demo credentials. You will want to use production credentials for environments that have controlled access data. Please specify which of these use-cases applies in your request. The Auth0 Application created to obtain this CLIENT_ID and CLIENT_SECRET must have OpenID-Connect Compliance turned off in the Auth0 settings.
-   Before you can safely run the system in production you will need a SSL certificate, chain, and key that is compatible with Apache HTTPD. If you are unable to obtain secure SSL certs and key, and are taking steps to keep your system from being accessible to the public internet you can choose to accept the risk that someone may steal your data or hijack your server by using the development certs and key that come installed by default. -- *USE THE DEFAULT CERTS AND KEY AT YOUR OWN RISK* --

**Steps to install pic-sure-all-in-one project on a RHEL 8.4**

  1. Install git
     - yum -y install git (if not already installed)
  2. Clone the pic-sure redhat branch All-in-one repository
     - cd /usr/local/docker-config
   	  - git clone -b feature/redhat https://github.com/hms-dbmi/pic-sure-all-in-one
  3. Navigate to pic-sure-all-in-one project directory to access startup
	  - cd pic-sure-all-in-one/initial-configuration
  4. Download and copy **jboss-eap-7.4.0.zip** file from local to ec2 instance
  	  - **Example**: if you have Jboss-eap-7.4.0.zip redhat file in your local Downloads directory, scp the file to ec2 instance pics-sure-all-in-one config location “**/usr/local/docker-config/pic-sure-all-in-one/initial-configuration/config/wildfly”**
  	  - sudo scp -i your-ec2-instance.pem ~/Downloads/jboss-eap-7.4.0.zip ec2-user@your-ec2-instance.amazon.com:/usr/local/docker-config/pic-sure-all-in-one/initial-configuration/config/wildfly
  5. Run The redhat install dependencies script, This script will install all necessary dependency to run project, MariaDB server, jenkins server, copy the necessary file changes to respective mount locations, create necessary directories
  	  - **./redhat-install-dependencies.sh**
   
     **Note:** Please check the console output while the script is executing, MariaDB is started and jenkins server started without any errors 
   
  6. Verify jenkins server is running and browse to jenkins server
	  - Check jenkins process is running on the system using ps command.
	  	- ps -aef|grep jenkins
	  - If jenkins process is running, Point your browser at your server's IP on port 8080. Or localhost port 8080
	  - For example, to access jenkins on localhost **http://localhost:8080**
	  - If your server has IP 10.89.144.12, please browse to **http://10.89.144.12:8080**
	  - If you are not able to access jenkins from the browser, you can launch a seperate ssh session of Ec2 instance local port forwarding using pem file or private key
	  	- From Ec2 to do local port forward to access jenkins you can use below example, 
  	  	- **example** : sudo ssh -i your-ec2-pem-file-or-private-key-file -L 8080:localhost:8080  ec2_user@your-ec2-instance.amazon.com 
	  - When you try to access the jenkins server from browser first time, it will ask for jenkins intial administartive password to unlock the jenkins server, the initial jenkins password is located in "/var/jenkins_home/secrets/initialAdminPassword" location, cat the file and copy the secret, paste it in the "Adminstrator Password" textbox. click continue button
	  	- sudo cat /var/jenkins_home/secrets/initialAdminPassword 
	  - On customize jenkins screen, select "Install suggested plugins" box, it will install required jenkins plugins for this project
	  - Need to create first adminstartor user, Enter jenkins default admin username, firstname, password, email address click  "save and continue" button
	  - Click on "Save and Finish"  button.
	  - Click on "Start Jenkins" button. Jenkins will start and displays the jenkins homescreen 

     **Note**: Work with your local IT department to ensure that this port is not available to the public internet, but is accessible to you on your intranet or VPN. anyone with access to this port can launch any application they wish on your server.

  7. In Jenkins you will see 5 tabs: All, Configuration, Deployment, "PIC-SURE Builds", "Supporting Jobs"
    Click the Configuration tab, then click the button to the right of the "Initial Configuration Pipeline" job. It resembles a clock with a green triangle on it.
    Provide the following information:

	  1. AUTH0_CLIENT_ID: This is the client_id of your auth0 application
	  2. AUTH0_CLIENT_SECRET: This is the client_secret of your auth0 application
	  3  AUTH0_TENANT: This is the first part of your auth0 domain, for example if your domain is avillachlab.auth0.com you would enter avillachlab in this field
	  4. EMAIL: This is the google account that will be the initial admin user.
	  5. PROJECT_SPECIFIC_OVERRIDE_REPOSITORY: This is the repo that contains the project specific overrides for your project. If you just want the default PIC-SURE behavior use this repo : <https://github.com/hms-dbmi/baseline-pic-sure>
	  6. RELEASE_CONTROL_REPOSITORY: This is the repo that contains the build-spec.json file for your project. This file controls what code is built and deployed. If you just want the default PIC-SURE behavior use this repo : <https://github.com/hms-dbmi/baseline-pic-sure-release-control>
	  7. Click the "Build" button.
	  8. Wait until all jobs complete. This may take several minutes. When nothing displays in the "Build Queue" or "Build Executor Status" to the left of the page, all jobs will have completed.
	  
**Note**: Ensure none of these fields contain leading or trailing whitespace, the values must be exact. Once you have entered the information, before trigger build
    
8. Click the All tab to ensure nothing displays with a red dot next to it. If you see any red dots, please try restarting with a fresh redhat 8.4 install. If you consistently have one or more jobs fail and display red dots, please reach out to [http://avillachlabsupport.hms.harvard.edu](http://avillachlabsupport.hms.harvard.edu/) for help.
    If all jobs have blue dots except the "Check For Updates" and "Configure SSL Certificates job", which should be gray, you can log into the UI for the first time.
	  - To access pic-sure application locally from browser add an alias/route for picsure.local to map your host ip in hosts file
    on the host as root/admin user
    	  - **example** : 127.0.0.1 is my local host and picsure.local is url which accessed from browser
    	  - For mac, Llnux based operating system users can edit /etc/hosts file and update the entry for picsure.local, and save the file
    	  	- sudo vi /etc/hosts
    	  	- 127.0.0.1 picsure.local
    	  - For Windows operating system users can edit c:\Windows\System32\Drivers\etc\hosts file and update the entry for picsure.local and save the file.
    	  	- Launch notpad in administartive mode
    	  	- open c:\Windows\System32\Drivers\etc\hosts file and update the picsure.local entry
    	  	- 127.0.0.1 picsure.local
    	  
  	  - From Ec2 to do local port forward to access picsure.local you can use below example
  	  	- **example** : sudo ssh -i yuurec2pemfile.pem -L 8080:localhost:8080 -L 443:localhost:443 ec2_user@your-ec2-instance.amazon.com
10. Navigate to browser and enter https://picsure.local
11. Log in using your google account that you have previously configured
12. Once you have confirmed that you can access the PIC-SURE UI using your admin user, stop the jenkins server by using stop-local-jenkins.sh 
  	  - cd /usr/local/docker-config/pic-sure-all-in-one/initial-configuration
          - ./stop-local-jenkins.sh
13. Instructions to start, stop jenkins on the host
	  -  **To start jenkins service**
    		- cd /usr/local/docker-config/pic-sure-all-in-one/initial-configuration
    		- ./start-local-jenkins.sh **or** sudo ./start-local-jenkins.sh
	  - **To stop jenkins service**
	  	- cd /usr/local/docker-config/pic-sure-all-in-one/initial-configuration
 	   	- ./stop-local-jenkins.sh **or** sudo ./stop-local-jenkins.sh
	  - **To check the state of jenkins**
   		- systemctl status jenkins **or** sudo systemctl status jenkins 
	  - **Jenkins log file location**
   		- /var/log/jenkins/jenkins.log   
14. Instructions to start, stop pic-sure application from host
	  - **To stop pic-sure application**
  		- cd /usr/local/docker-config/pic-sure-all-in-one
  		- ./stop-picsure-redhat.sh
          - **To start pic-sure application**
   		- cd /usr/local/docker-config/pic-sure-all-in-one
   		- ./start-picsure-redhat.sh
15. Log directory locations.
	- Hpds container log file location:
		- /var/log/hpds-logs
	- Apache httpd container log file location, This location is mounted to /usr/local/apache2/logs you will find access logs, ssl logs, error logs for httpd request in this location
		- /var/log/httpd-docker-logs
	- Jboss Container log file location, This location  is volume mounted to $JBOSS_HOME/logs/ logs directory of jboss container server.log 
		- /var/log/wildfly-docker-logs
	- Jboss container os log file location, This location is volume mounted to jboss container to the /var/log/  location.
		- /var/log/wildfly-docker-os-logs/
	

**Note**: If multiple users need to login to pic-sure-application we need to create an user and set as pic-sure user
