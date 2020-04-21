# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

# Configuration file for JupyterHub
import os
import types
import dockerspawner
import errno

c = get_config()

# Spawn single-user servers as Docker containers
c.JupyterHub.spawner_class = 'dockerspawner.DockerSpawner'
# Spawn containers from this image
c.DockerSpawner.image = 'jupyter/datascience-notebook:hub-1.1.0'

# JupyterHub requires a single-user instance of the Notebook server, so we
# default to using the `start-singleuser.sh` script included in the
# jupyter/docker-stacks *-notebook images as the Docker run command when
# spawning containers.  Optionally, you can override the Docker run command
# using the DOCKER_SPAWN_CMD environment variable.
spawn_cmd = 'start-singleuser.sh'
c.DockerSpawner.extra_create_kwargs.update({ 'command': spawn_cmd })
# Connect containers to this Docker network
network_name = 'picsure'
c.DockerSpawner.use_internal_ip = True
c.DockerSpawner.network_name = network_name
# Pass the network name as argument to spawned containers
c.DockerSpawner.extra_host_config = { 'network_mode': network_name }
# Explicitly set notebook directory because we'll be mounting a host volume to
# it.  Most jupyter/docker-stacks *-notebook images run the Notebook server as
# user `jovyan`, and set the notebook directory to `/home/jovyan/work`.
# We follow the same convention.
notebook_dir = '/home/jovyan'
c.DockerSpawner.notebook_dir = notebook_dir
# Remove containers once they are stopped
c.DockerSpawner.remove_containers = True
# For debugging arguments passed to spawned containers
c.DockerSpawner.debug = True

# User containers will access hub by container name on the Docker network
c.JupyterHub.hub_ip = 'jupyterhub'
c.JupyterHub.hub_port = 8080
c.JupyterHub.base_url = '/jupyterhub'


c.JupyterHub.authenticator_class = 'jupyterhub.auth.DummyAuthenticator'

# Persist hub data on volume mounted inside container
data_dir = '/data'
c.JupyterHub.db_url = os.path.join('sqlite:///', data_dir, 'jupyterhub.sqlite')
c.JupyterHub.cookie_secret_file = os.path.join(data_dir,
    'jupyterhub_cookie_secret')

# Mount the real user's Docker volume on the host to the notebook user's
# notebook directory in the container
# also mount a readonly and shared folder
c.DockerSpawner.volumes = { 'jupyterhub-user-{username}': notebook_dir }
#c.DockerSpawner.extra_create_kwargs.update({ 'volume_driver': 'local' })

c.DockerSpawner.format_volume_name = dockerspawner.volumenamingstrategy.escaped_format_volume_name

# Whitlelist users and admins
c.Authenticator.whitelist = whitelist = set()
c.Authenticator.admin_users = admin = set()
c.JupyterHub.admin_access = True
c.DummyAuthenticator.password = "__JUPYTER_PASSWORD__"

c.JupyterHub.hub_ip = '0.0.0.0'
c.DockerSpawner.hub_ip_connect = '127.0.0.1'
