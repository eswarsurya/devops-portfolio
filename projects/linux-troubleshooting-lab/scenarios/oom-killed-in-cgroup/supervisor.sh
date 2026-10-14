#!/usr/bin/env bash
# Keeps one cache-worker running, like a process manager (gunicorn, supervisord).
# Logs how each worker ended, so a crash loop shows up in the journal.
conf="$1"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while true; do
  python3 "$here/cache_worker.py" "$conf"
  rc=$?
  echo "supervisor: cache-worker exited with status $rc, restarting in 2s"
  sleep 2
done
