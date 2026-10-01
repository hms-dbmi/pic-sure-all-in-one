#!/usr/bin/env bash

# AIO's named volumes and HPDS service use root-owned files. Keep ETL writes
# compatible when the upstream image changes USER. Operators who prepare their
# own volume permissions can override this with ETL_RUN_AS=1000:1000 in .env.
picsure_etl_run() {
  docker run --rm --user "${ETL_RUN_AS:-0:0}" "$@"
}
