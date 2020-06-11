FROM jupyterhub/jupyterhub:1.2

RUN pip3 install dockerspawner
RUN git clone https://github.com/hms-dbmi/jupyterhub_psama_authenticator.git /srv/jupyterhub_psama_authenticator
RUN pip3 install /srv/jupyterhub_psama_authenticator
