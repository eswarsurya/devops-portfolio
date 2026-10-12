#!/usr/bin/env bash
# Chaos for the live demo on a real cluster: deploy a "bad release" of the app
# that crash-loops, then watch the agent find it and propose `rollout undo`.
#
#   NS=prod DEPLOY=incident-api ./scripts/break-it.sh
set -euo pipefail
NS="${NS:-prod}"
DEPLOY="${DEPLOY:-incident-api}"

echo "Breaking $DEPLOY in $NS: new revision whose container exits on start..."
kubectl -n "$NS" patch deployment "$DEPLOY" --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/command",
   "value":["python","-c","import os; os.environ[\"DATABASE_URL\"]"]}
]'
kubectl -n "$NS" rollout status deployment "$DEPLOY" --timeout=60s || true
kubectl -n "$NS" get pods
echo
echo "Within ~2 minutes the IncidentApiDown alert fires -> open the triage dashboard."
echo "Fix by hand instead:  kubectl -n $NS rollout undo deployment/$DEPLOY"
