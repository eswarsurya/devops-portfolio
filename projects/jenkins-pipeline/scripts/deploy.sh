#!/usr/bin/env bash
# Deploy an image to one environment and roll back if it doesn't pass its health check.
# Usage: deploy.sh <staging|production> <image>
set -euo pipefail

env_name=${1:?usage: deploy.sh <staging|production> <image>}
image=${2:?usage: deploy.sh <staging|production> <image>}
name="incident-api-${env_name}"
network=${DEPLOY_NETWORK:-jenkins-demo}
tries=${HEALTH_TRIES:-30}

healthy() {
  local i
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS --max-time 2 "http://${name}:8000/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start() {
  docker run -d --name "$name" --network "$network" \
    --label "env=${env_name}" --restart unless-stopped "$1" >/dev/null
}

previous=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)
echo "Deploying ${image} to ${env_name} (currently: ${previous:-nothing})"

docker rm -f "$name" >/dev/null 2>&1 || true
start "$image"

if healthy; then
  echo "${env_name} is healthy on ${image}"
  exit 0
fi

echo "Health check failed for ${image}. Last log lines:"
docker logs --tail 20 "$name" 2>&1 || true
docker rm -f "$name" >/dev/null

if [[ -n "$previous" ]]; then
  echo "Rolling ${env_name} back to ${previous}"
  start "$previous"
  if healthy; then
    echo "Rollback complete: ${env_name} is healthy on ${previous}"
  else
    echo "Rollback image is unhealthy too. ${env_name} needs attention."
  fi
else
  echo "No previous version to roll back to."
fi
exit 1
