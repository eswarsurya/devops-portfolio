#!/usr/bin/env bash
set -uo pipefail
systemctl stop lab-cache.service 2>/dev/null || true
systemctl reset-failed lab-cache.service 2>/dev/null || true
exit 0
