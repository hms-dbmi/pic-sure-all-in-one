# pic-sure-all-in-one

Assumptions:

- This system will be maintained by someone with either a basic understanding of Docker or the will to learn and develop that understanding over time.
- You already have installed Git on the server and have internet access from the server.

Preparing to deploy:

You will be creating an initial admin user tied to a Google account. Decide which one you want to use.

You will need an Auth0 Client Secret and Client ID. If these have not been provided for you, create a free Auth0 account and use it to create an Application. When you create an Auth0 Application for PIC-SURE, select "Regular Web Application" and in the Advanced Settings under the OAuth tab turn the OIDC Conformant switch off. If you are using your own Auth0 account or anything other than the avillachlab Auth0 account, you will have to also provide an AUTH0_TENANT value to the Configure Auth0 Integration Jenkins job. Configuring your Auth0 account is outside the scope of this project. 

You will need an SSL certificate, chain and key that is compatible with Apache HTTPD. If you are unable to obtain secure SSL certs and key, and are taking steps to keep your system from being accessible to the public internet you can accept the risk that someone may steal your data or hijack your server by using these development certs and key:

https://github.com/hms-dbmi/biodatacatalyst-pic-sure/tree/master/biodatacatalyst-ui/dev-cert



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
Point your browser at your server on port 8080. Work with your local IT department to make sure that this port is not available to the public internet, but is accessible to you when on your intranet or VPN.

If your server has IP 10.109.190.146, you would browse to http://10.109.190.146:8080

In Jenkins you will see 5 tabs: All, Configuration, Deployment, PIC-SURE Builds, Supporting Jobs

You will need to run jobs on the Configuration and Deployment tabs in the following order to result in a working system. If you do not follow the instructions, start over with a fresh Centos 7 installation. The Jenkins server will automatically run the PIC-SURE Builds jobs, don't panic if you see them running, this is normal. Just please focus and go through the following steps in order waiting for each job to finish before going on to the next:

1) Deployment/PIC-SURE Database Migrations - This will create the necessary database schemas.

2) Configuration/Configure Auth0 Integration - When you run this Jenkins will ask you to provide the AUTH0_CLIENT_ID and AUTH0_CLIENT_SECRET. Copy and paste the AUTH0_CLIENT_ID and AUTH0_CLIENT_SECRET into the text fields. If you are using an Auth0 account other than the avillachlab one then you will also need to change the AUTH0_TENANT value.

3) Configuration/Configure SSL Certificates - You will need to provide an Apache HTTPD compatible set of SSL certificate, chain and key. Reach out to your local IT department if you do not know how to obtain these. Even if you are running the application internally you still need SSL enabled to host the system responsibly. If you are only using this for testing the system out and decide to accept the risk, you can download these files which are public and provide no actual security as a result: 

https://github.com/hms-dbmi/biodatacatalyst-pic-sure/tree/master/biodatacatalyst-ui/dev-cert

4) Configuration/Configure PIC-SURE Token Introspection Token - This will create internal credentials used by PIC-SURE to communicate securely.

5) Configuration/Create Admin User - This will create an initial admin user in PIC-SURE using your Google account. Put your gmail in the EMAIL field, once the system is deployed you can use the Admin UI to create a new Admin user and deactivate your Google user. If you choose to deactivate your Google user, please test that the other admin user you have created actually has the necessary access to manage your users.

By this point all the PIC-SURE Builds jobs should have completed. Check the All tab to make sure nothing shows with a red dot next to it. If you see any red dots(instead of blue or grey), and you are sure you followed the instructions perfectly, try starting from scratch with a fresh Centos7 install. If you consistently have the same job(s) fail(red dots) then you should reach out to avillach_lab_developers@googlegroups.com for help.

If all jobs have blue dots except the Backup Jenkins Home job and the Deploy PIC-SURE job then you are ready to Deploy PIC-SURE. Run Deploy PIC-SURE.

After about a minute you should be able to log into the PIC-SURE application. To do this, browse to this URL after replacing example.com with your actual server IP or domain name:

https://example.com/psamaui/?redirection_url=/psamaui

Log in using your Google account that you configured in step 5 above.

This will bring you to the User management page. From here you can create additional users or manage the roles of existing users. Click on the user that you added.

You will see a variety of technical details related to this user and the roles they are assigned. Click the Edit button and add the PIC-SURE User role to your user using the checkbox and hit save so you can browse the PIC-SURE UI.

Click Applications, then PIC-SURE to be sent to the PIC-SURE UI.




