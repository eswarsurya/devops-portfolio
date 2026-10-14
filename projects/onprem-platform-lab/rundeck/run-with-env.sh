#!/bin/bash
# Rundeck job entry point: loads the lab settings (monitor password, Elasticsearch URL), then runs the given command.
set -a
# shellcheck disable=SC1091
. /opt/lab/env/monitor.env
set +a
exec "$@"
