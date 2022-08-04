**update-jenkins-job.sh**
  - Instructions to run the script update-jenkins-jobs.sh
    1) Stop the jenkins
       - **cd /usr/local/docker-config/pic-sure-all-in-one/initial-configuration**
       - **./stop-local-jenkins.sh or sudo ./stop-local-jenkins.sh**
	  2) Check jenkins status
	     - **sudo systemctl status jenkins**
	     - **ps -aef|grep jenkins**
	  3) Navigate to pic-sure-all-in-one directory
	     - **sudo cd /usr/local/docker-config/pic-sure-all-in-one**
	  4) Pull latest code from git repository
	     - **sudo git fetch**
	     - **sudo git pull**
	  5) Navigate to utils directory to update-jenkins-jobs.sh
	     - **sudo cd /usr/local/docker-config/pic-sure-all-in-one/initial-configuration/utils**
  	  6) Run the script update-jenkins-jobs.sh
  	     - **sudo ./update-jenkins-jobs.sh**
	
	Note: This script will deploy latest jenkins jobs to existing pic-sure installation on the host
	
	  7) Start jenkins
	     - **sudo cd /usr/local/docker-config/pic-sure-all-in-one/initial-configuration**
	     - **sudo ./start-local-jenkins.sh or sudo ./start-local-jenkins.sh**
   	  8) Verify jenkins server is running and browse to jenkins server
	     - Check jenkins process is running on the system using ps command.
	     - **ps -aef|grep jenkins**
	     - If jenkins process is running, Point your browser at your server's IP on port 8080. Or localhost port 8080
	     - For example, to access jenkins on localhost **http://localhost:8080**
	  9) In jenkins you will see 5 tabs: All, Configuration, Deployment, "PIC-SURE Builds", "Supporting Jobs" click the Deployment tab, then click the button to the right of the "Cleanup Containers and Images" job. It resembles a clock with a green triangle on it
	     - http://localhost:8080/job/Cleanup%20Containers%20and%20Images/
	10) Click the Deployment tab, then click the button to the right of the "Check for Updates" job. It resembles a clock with a green triangle on it.
	    - http://localhost:8080/job/Check%20For%20Updates/
	11) Click the Deployment tab, then click the button to the right of the "Start PIC-SURE" job. It resembles a clock with a green triangle on it.
	     - http://localhost:8080/job/Start%20PIC-SURE/
	12) Click the Deployment tab, then click the button to the right of the "Cleanup Containers and Images" job. It resembles a clock with a green triangle on it.
	     - http://localhost:8080/job/Cleanup%20Containers%20and%20Images/

