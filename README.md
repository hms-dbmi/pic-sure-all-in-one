# pic-sure-all-in-one

Assumptions:

- This system will be maintained by someone with either a basic understanding of Docker or the will to learn and develop that understanding over time.
- You have internet access from the server as well as network connectivity to the server from your browser on ports 80, 443 and 8443

Preparing to deploy:

You will be creating an initial admin user tied to a Google account. Decide which google account you want to use.

You will need an Auth0 Client Secret(AUTH0_CLIENT_SECRET) and Client ID(AUTH0_CLIENT_ID). If these have not been provided for you, create a free Auth0 account and use it to create an Application. When you create an Auth0 Application for PIC-SURE, select "Regular Web Application" and in the Advanced Settings under the OAuth tab turn the OIDC Conformant switch off. If you are using your own Auth0 account or anything other than the avillachlab Auth0 account, you will have to also provide an AUTH0_TENANT value to the Configure Auth0 Integration Jenkins job. Configuring your Auth0 account is outside the scope of this project. 

Before you can safely run the system in production you will need an SSL certificate, chain and key that is compatible with Apache HTTPD. If you are unable to obtain secure SSL certs and key, and are taking steps to keep your system from being accessible to the public internet you can choose to accept the risk that someone may steal your data or hijack your server by using the development certs and key that come installed by default. -- USE THE DEFAULT CERTS AND KEY AT YOUR OWN RISK --


Minimum System Requirements:

- 32 GB of RAM
- 8 cores
- 100 GB of hard drive space plus enough to hold your data
- Only Centos 7 is supported for operating systems

# Steps to install on a fresh Centos 7 installation:

- Install Git

yum -y install git

- Clone the PIC-SURE All-in-one repository

git clone https://github.com/hms-dbmi/pic-sure-all-in-one

- Install the dependencies and build the Jenkins container

cd pic-sure-all-in-one/initial-configuration
./install-dependencies

- Start Jenkins server

cd ../
./start-jenkins.sh

- Browse to Jenkins server

Point your browser at your server's IP on port 8080. Work with your local IT department to make sure that this port is not available to the public internet, but is accessible to you when on your intranet or VPN. Anyone with access to this port can launch any application they wish on your server.

If your server has IP 10.109.190.146, you would browse to http://10.109.190.146:8080

In Jenkins you will see 5 tabs: All, Configuration, Deployment, PIC-SURE Builds, Supporting Jobs

On the Deployment tab click the button to the right of the Initial Configuration Pipeline job. It looks something like a sundial with a green triangle on it. You will then be asked for the following information:

AUTH0_CLIENT_ID - This is the client_id of your Auth0 Application
AUTH0_CLIENT_SECRET - This is the client_secret of your Auth0 Application
AUTH0_TENANT - This is the first part of your Auth0 domain, for example if your domain is avillachlab.auth0.com you would enter avillachlab in this field.
EMAIL - This is the Google account that will be the initial admin user.
PROJECT_SPECIFIC_OVERRIDE_REPOSITORY - This is the repo that contains the project specific overrides for your project.
RELEASE_CONTROL_REPOSITORY - This is the repo that contains the build-spec.json file for your project. This file controls what code is built and deployed.

Once you have entered the information, click the "Build" button.

Wait until all jobs complete, it will take at least several minutes. When there is nothing showing in the Build Queue or Build Executor Status to the left of the page, all jobs will have completed.

Check the All tab to make sure nothing shows with a red dot next to it. If you see any red dots try starting from scratch with a fresh Centos7 install. If you consistently have the same job(s) fail(red dots) then you should reach out to avillach_lab_developers@googlegroups.com for help.

If all jobs have blue dots except the Check For Updates and Configure SSL Certificates job, which should be gray, you should be able to log into the UI for the first time. Browse to the same domain or IP address as your Jenkins server, but without the 8080 port.

Log in using your Google account that you configured in step 5 above.

Once you have confirmed that you can access the PIC-SURE UI using your admin user, stop the jenkins server by runnning the stop-jenkins.sh script:

./stop-jenkins.sh
