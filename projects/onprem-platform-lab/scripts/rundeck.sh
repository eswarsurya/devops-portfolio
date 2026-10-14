#!/usr/bin/env bash
# Small Rundeck API client for the lab.
#   rundeck.sh import          create the dublin-dc project and import rundeck/jobs/runbooks.yaml
#   rundeck.sh run <job name>  run a job, wait for it, print its log; exit 0 only if it succeeded
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

API=${RUNDECK_URL:-http://localhost:4440}/api/46
PROJECT=dublin-dc
call() { curl -fsS -H "X-Rundeck-Auth-Token: $RUNDECK_API_TOKEN" -H 'Accept: application/json' "$@"; }

wait_ready() {
  for _ in $(seq 1 90); do
    call "$API/system/info" >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "Rundeck API did not come up" >&2; return 1
}

job_id() {
  call "$API/project/$PROJECT/jobs" | python3 -c "import json,sys; print(next(j['id'] for j in json.load(sys.stdin) if j['name']==sys.argv[1]))" "$1"
}

case "${1:-}" in
  import)
    wait_ready
    call -X POST -H 'Content-Type: application/json' -d "{\"name\":\"$PROJECT\"}" "$API/projects" >/dev/null 2>&1 || true
    call -X POST -H 'Content-Type: application/yaml' --data-binary @rundeck/jobs/runbooks.yaml \
      "$API/project/$PROJECT/jobs/import?format=yaml&dupeOption=update" \
      | python3 -c "import json,sys; r=json.load(sys.stdin); print('imported:', [j['name'] for j in r['succeeded']]); sys.exit(1 if r['failed'] else 0)"
    ;;
  run)
    id=$(job_id "$2")
    exec_id=$(call -X POST -H 'Content-Type: application/json' -d '{}' "$API/job/$id/run" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    for _ in $(seq 1 60); do
      st=$(call "$API/execution/$exec_id" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
      [ "$st" = running ] || break
      sleep 2
    done
    call "$API/execution/$exec_id/output?format=json" | python3 -c "import json,sys; [print('   ', e.get('log','')) for e in json.load(sys.stdin).get('entries',[])]"
    echo "job '$2' -> $st"
    [ "$st" = succeeded ]
    ;;
  *) sed -n '2,4p' "$0"; exit 1 ;;
esac
