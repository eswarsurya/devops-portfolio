#!/usr/bin/env bash
# Healthy = the client can reach the service over the network.
set -euo pipefail
ip netns exec lab-bind-cli curl -sS --max-time 5 http://10.202.0.1:8080/
