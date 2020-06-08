# pic-sure-all-in-one

Assumptions:

- This system will be maintained by someone with either a basic understanding of Docker or the will to learn and develop that understanding over time.

- The server can access the internet and your browser can access the server on ports 80, 443, 8080

- You have sudo privileges or root account access on the server.

Preparing to deploy:

- You will create an initial admin user tied to a Google account. Decide which google account you want to use.

- You need an Auth0 Client Secret(AUTH0_CLIENT_SECRET), Client ID(AUTH0_CLIENT_ID), and an AUTH0_TENANT value for the Configure Auth0 Integration Jenkins job .Please contact us at avillach_lab_developers@googlegroups.com and these will be sent to you.

- Before you can safely run the system in production you will need an SSL certificate, chain and key that is compatible with Apache HTTPD. If you are unable to obtain secure SSL certs and key, and are taking steps to keep your system from being accessible to the public internet you can choose to accept the risk that someone may steal your data or hijack your server by using the development certs and key that come installed by default. -- *USE THE DEFAULT CERTS AND KEY AT YOUR OWN RISK* --


Minimum System Requirements:

- 32 GB of RAM
- 8 cores
- 100 GB of hard drive space plus enough to hold your data
- Only Centos 7 is supported for operating systems

# Steps to install on a fresh Centos 7 installation:

1. Install Git

sudo yum -y install git

2. Clone the PIC-SURE All-in-one repository

git clone https://github.com/hms-dbmi/pic-sure-all-in-one

3. Install the dependencies and build the Jenkins container

cd pic-sure-all-in-one/initial-configuration

sudo ./install-dependencies.sh

4. Browse to Jenkins server

5. Point your browser at your server's IP on port 8080. 

For example, if your server has IP 10.109.190.146, please browse to http://10.109.190.146:8080

Note: Work with your local IT department to ensure that this port is not available to the public internet, but is accessible to you on your intranet or VPN. Anyone with access to this port can launch any application they wish on your server.

6. In Jenkins you will see 5 tabs: All, Configuration, Deployment, PIC-SURE Builds, Supporting Jobs

Click the Configuration tab, then click the button to the right of the Initial Configuration Pipeline job. It resembles a clock with a green triangle on it. 

7. Provide the following information:

    - AUTH0_CLIENT_ID: This is the client_id of your Auth0 Application

    - AUTH0_CLIENT_SECRET: This is the client_secret of your Auth0 Application

    - AUTH0_TENANT: This is the first part of your Auth0 domain, for example if your domain is avillachlab.auth0.com you would   enter avillachlab in this field.

    - EMAIL: This is the Google account that will be the initial admin user.

    - PROJECT_SPECIFIC_OVERRIDE_REPOSITORY: This is the repo that contains the project specific overrides for your project. If you just want the default PIC-SURE behavior use this repo : https://github.com/hms-dbmi/baseline-pic-sure

    - RELEASE_CONTROL_REPOSITORY: This is the repo that contains the build-spec.json file for your project. This file controls what code is built and deployed. If you just want the default PIC-SURE behavior use this repo : https://github.com/hms-dbmi/baseline-pic-sure-release-control

Note: Ensure none of these fields contain leading or trailing whitespace, the values must be exact. Once you have entered the information,

8. Click the "Build" button.

Wait until all jobs complete. This may take several minutes. When nothing displays in the Build Queue or Build Executor Status to the left of the page, all jobs will have completed.

9. Click the All tab to ensure nothing displays with a red dot next to it. If you see any red dots, please try restarting with a fresh Centos7 install. If you consistently have one or more jobs fail and display red dots, please reach out to avillach_lab_developers@googlegroups.com for help.

If all jobs have blue dots except the Check For Updates and Configure SSL Certificates job, which should be gray, you can log into the UI for the first time. 

10. Browse to the same domain or IP address as your Jenkins server without the 8080 port.

For example, if your server has IP 10.109.190.146, you would browse to https://10.109.190.146

11. Log in using your Google account that you previously configured.

12. Once you have confirmed that you can access the PIC-SURE UI using your admin user, stop the jenkins server by runnning the following stop-jenkins.sh script:

sudo ./stop-jenkins.sh


# Additional Information:

- Any time you wish to update the system, please run the update-jenkins.sh script and then start the Jenkins server. This ensures the jenkins jobs and configurations are up to date.  

- Always stop Jenkins using the stop-jenkins.sh script when you are done to prevent unauthorized access as Jenkins effectively has root privileges on your server.

- To start or stop PIC-SURE use the "Start PIC-SURE" and "Stop PIC-SURE" jobs.

- To start or stop JupyterHub use the "Start JupyterHub" and "Stop JupyterHub" jobs. The Start JupyterHub job asks you to set a password. Currently this password is shared by all JupyterHub users, we are working to integrate JupyterHub with the PIC-SURE Auth Micro-App so that users can log in using the same credentials they use to access PIC-SURE UI. To access JupyterHub browse to your server ip address on the path /jupyterhub

For example, if your server has IP 10.109.190.146, browse to https://10.109.190.146/jupyterhub

- If you have an Apache HTTPD compatible certificate, chain, and key files for SSL configuration, navigate to the Configuration tab and run the Configure SSL Certificates job uploading your server.crt, server.chain, and server.key files using the Choose File buttons, then press the Build button. Once this completes, go to the Deployment tab and run the Deploy PIC-SURE job to restart your containers so the updated SSL configuration is used.

- As your project progresses you will run the Check For Updates job to pull and build the latest release of each component as the release control repository is updated. To deploy the latest updates after Check For Updates is run, execute the Start PIC-SURE job.

