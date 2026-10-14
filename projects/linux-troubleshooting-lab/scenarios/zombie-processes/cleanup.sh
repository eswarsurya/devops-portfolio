#!/usr/bin/env bash
set -uo pipefail
systemctl stop lab-batch.service 2>/dev/null || true
systemctl reset-failed lab-batch.service 2>/dev/null || true
exit 0
