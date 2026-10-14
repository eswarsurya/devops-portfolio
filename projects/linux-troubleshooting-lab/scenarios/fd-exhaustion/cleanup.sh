#!/usr/bin/env bash
set -uo pipefail
systemctl stop lab-upload-api.service 2>/dev/null || true
systemctl reset-failed lab-upload-api.service 2>/dev/null || true
exit 0
