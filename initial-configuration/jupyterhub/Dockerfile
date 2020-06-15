FROM jupyterhub/jupyterhub:1.2

RUN pip3 install dockerspawner
RUN apt-get update && apt-get install -y git
RUN git clone https://github.com/hms-dbmi/jupyterhub_psama_authenticator.git /srv/jupyterhub_psama_authenticator
RUN pip3 install -e /srv/jupyterhub_psama_authenticator
