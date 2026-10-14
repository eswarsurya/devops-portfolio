#!/usr/bin/env bash
# Healthy = the client reaches both services.
set -euo pipefail
ip netns exec lab-fw-cli curl -sS --connect-timeout 3 http://10.203.0.1:8080/
ip netns exec lab-fw-cli curl -sS --connect-timeout 3 http://10.203.0.1:8081/
