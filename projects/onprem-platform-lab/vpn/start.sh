#!/bin/sh
# Brings up the site-to-site tunnel. On the data-centre side it also routes branch traffic into the lab network.
set -eu
wg-quick up wg0
if [ "${ROLE:-}" = "dc" ]; then
  # branch hosts reach lab services as if from the gateway (no return route needed on every lab host)
  iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -d 172.30.10.0/24 -j MASQUERADE
fi
wg show
exec sleep infinity
