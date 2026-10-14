#!/usr/bin/env bash
# Healthy = no packet loss and average RTT under 10 ms across the router,
# and a 1 MB download completes.
set -euo pipefail
out="$(ip netns exec lab-net-cli ping -c 20 -i 0.2 -q 10.204.2.10 || true)"
echo "$out"
loss="$(grep -oE '[0-9.]+% packet loss' <<<"$out" | cut -d% -f1)"
avg="$(grep -oE '= [0-9.]+/[0-9.]+' <<<"$out" | cut -d/ -f2)"
echo "loss ${loss}%, avg rtt ${avg} ms"
if [[ "$loss" != "0" ]] || ! awk -v a="$avg" 'BEGIN { exit !(a < 10) }'; then
  exit 1
fi
ip netns exec lab-net-cli curl -sS -o /dev/null --max-time 20 \
  -w 'downloaded %{size_download} bytes in %{time_total}s\n' 'http://10.204.2.10:8080/blob?size=1000000'
