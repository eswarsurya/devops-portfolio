#!/usr/bin/env bash
# "orders-api hangs, billing-api says connection refused. Both teams swear their app is up."
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
PCAP="$ARTIFACTS/firewall-drop-vs-reject.pcap"

step "1. Start a packet capture on the client while we test"
ip netns exec lab-fw-cli tcpdump -Z root -i veth-fw-cli -nn -U -w "$PCAP" 'tcp port 8080 or tcp port 8081' \
  > "$STATE/tcpdump.log" 2>&1 &
tcpdump_pid=$!
wait_until 5 grep -q 'listening on' "$STATE/tcpdump.log"
echo "$ ip netns exec lab-fw-cli tcpdump -Z root -i veth-fw-cli -nn -U -w $(basename "$PCAP") 'tcp port 8080 or tcp port 8081'"

step "2. Time both connections (connect timeout 3s)"
result() {
  local port="$1" rc=0 out
  out="$(ip netns exec lab-fw-cli curl -s -o /dev/null --connect-timeout 3 \
    -w 'time_connect=%{time_connect}s time_total=%{time_total}s' "http://10.203.0.1:$port/")" || rc=$?
  echo "port $port: curl exit $rc, $out" >&2
  case "$rc" in 28) echo timeout ;; 7) echo refused ;; 0) echo ok ;; *) echo "exit_$rc" ;; esac
}
r8080="$(result 8080)"
r8081="$(result 8081)"
echo "8080: $r8080 (curl exit 28 = gave up waiting; no answer at all)"
echo "8081: $r8081 (curl exit 7 = actively refused, at once)"

sleep 1
kill -INT "$tcpdump_pid" 2>/dev/null
wait "$tcpdump_pid" 2>/dev/null

step "3. What was on the wire?"
show tcpdump -nn -r "$PCAP"
syn8080="$(tcpdump -nn -r "$PCAP" 'tcp dst port 8080 and tcp[tcpflags] & tcp-syn != 0' 2>/dev/null | wc -l)"
synack8080="$(tcpdump -nn -r "$PCAP" 'tcp src port 8080 and tcp[tcpflags] & (tcp-syn|tcp-ack) == (tcp-syn|tcp-ack)' 2>/dev/null | wc -l)"
rst8081="$(tcpdump -nn -r "$PCAP" 'tcp src port 8081 and tcp[tcpflags] & tcp-rst != 0' 2>/dev/null | wc -l)"
echo "SYNs sent to 8080: $syn8080, SYN-ACKs back from 8080: $synack8080 (the client kept retrying a SYN nobody answered)"
echo "RSTs back from 8081: $rst8081 (a reset arrived for the first SYN)"
show_sh "tshark -r $PCAP -Y 'tcp.flags.reset == 1 || tcp.analysis.retransmission' -T fields -e frame.time_relative -e ip.src -e tcp.srcport -e tcp.dstport -e _ws.col.Info 2>/dev/null"

step "4. Are the apps even listening? (yes: so it is not the apps)"
show ip netns exec lab-fw-srv ss -ltnp

step "5. Firewall on the server, with packet counters"
show ip netns exec lab-fw-srv nft -a list ruleset
rules="$(ip netns exec lab-fw-srv nft list ruleset)"
drop_port="$(grep -oE 'tcp dport [0-9]+ counter packets [0-9]+ bytes [0-9]+ drop' <<<"$rules" | awk '{print $3}' | head -1)"
reject_port="$(grep -oE 'tcp dport [0-9]+ counter packets [0-9]+ bytes [0-9]+ reject' <<<"$rules" | awk '{print $3}' | head -1)"
echo "DROP rule on $drop_port (the sender hears nothing, so it retries until it times out)"
echo "REJECT rule on $reject_port (the sender gets a RST at once: 'connection refused')"

finding port_8080 "$r8080"
finding port_8081 "$r8081"
finding drop_rule_port "$drop_port"
finding reject_rule_port "$reject_port"
finding synack_from_8080 "$([[ $synack8080 -gt 0 ]] && echo yes || echo no)"
finding rst_from_8081 "$([[ $rst8081 -gt 0 ]] && echo yes || echo no)"
