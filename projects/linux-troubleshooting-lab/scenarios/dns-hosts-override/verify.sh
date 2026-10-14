#!/usr/bin/env bash
# Healthy = the client reaches api.lab.internal by name.
set -euo pipefail
ip netns exec lab-dns-cli curl -sS --max-time 5 http://api.lab.internal:8080/
