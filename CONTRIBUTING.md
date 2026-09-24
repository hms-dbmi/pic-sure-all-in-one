# Contributing to PIC-SURE All-in-one

Please read the [PIC-SURE contributing guide](https://github.com/hms-dbmi/pic-sure/blob/main/CONTRIBUTING.md)
first. It covers the code of conduct, filing issues, and how pull requests are reviewed across
every PIC-SURE repository.

## Building and testing this repo

The all-in-one installs the whole PIC-SURE stack. It is not a lightweight development environment:
the README asks for 32 GB of RAM and 8 cores. The [README](README.md) has the system requirements,
the fresh-server install steps, and a separate section for Apple Silicon Macs. Follow those rather
than calling the scripts directly.

The current path is the fully dockerized install, `install-dependencies-docker.sh` run from inside
`initial-configuration/` with a config directory argument. The install finishes in Jenkins, not on
the command line. `install-dependencies.sh` is the legacy path and the README gates it behind
knowing what you are doing.
