#!/usr/bin/env bash
# "The client can't reach api.lab.internal, but DNS looks fine when I check it."
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
cli() { ip netns exec lab-dns-cli "$@"; }

step "1. The symptom, verbose: which address does curl actually try?"
show ip netns exec lab-dns-cli curl -sv --max-time 5 http://api.lab.internal:8080/

step "2. Ask DNS directly with dig (dig talks to the nameserver in resolv.conf and nothing else)"
show ip netns exec lab-dns-cli cat /etc/resolv.conf
show ip netns exec lab-dns-cli dig +noall +answer +stats api.lab.internal
dns_ip="$(cli dig +short api.lab.internal | head -1)"

step "3. Ask the way applications ask: getent uses the C library resolver and nsswitch.conf"
show ip netns exec lab-dns-cli getent ahostsv4 api.lab.internal
getent_ip="$(cli getent hosts api.lab.internal | awk '{print $1}' | head -1)"
echo "dig says $dns_ip, getent says $getent_ip."

cause=unknown
stale=""
if [[ -n "$dns_ip" && -n "$getent_ip" && "$dns_ip" != "$getent_ip" ]]; then
  step "4. They disagree. What does nsswitch.conf check before DNS?"
  show ip netns exec lab-dns-cli grep '^hosts:' /etc/nsswitch.conf
  echo "'files' comes first, so /etc/hosts wins over DNS."
  show ip netns exec lab-dns-cli grep -n 'api.lab.internal' /etc/hosts
  stale="$(cli grep -E '^[^#]*[[:space:]]api\.lab\.internal' /etc/hosts | awk '{print $1, $2}' | head -1)"
  [[ -n "$stale" ]] && cause=hosts_file_override
fi

step "5. Is the address from /etc/hosts even alive?"
show ip netns exec lab-dns-cli ping -c 2 -W 1 "$getent_ip"
show ip netns exec lab-dns-cli ip neigh show "$getent_ip"
echo "No ARP entry (FAILED/INCOMPLETE): nothing on the network answers for $getent_ip."

finding getent_ip "$getent_ip"
finding dns_ip "$dns_ip"
finding cause "$cause"
finding stale_line "$stale"
