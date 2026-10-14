#!/usr/bin/env bash
# "Downloads from files-api are slow and sometimes stall. The server is not busy."
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"
PCAP="$ARTIFACTS/packet-loss-and-latency.pcap"

step "1. Latency and loss end to end, then to the first hop"
show ip netns exec lab-net-cli ping -c 30 -i 0.2 -q 10.204.2.10
show ip netns exec lab-net-cli ping -c 15 -i 0.2 -q 10.204.1.1
echo "The first hop (the router) is already slow and lossy, so the problem is on the client <-> router link."

step "2. Capture on the server while a 1 MB download runs"
ip netns exec lab-net-srv tcpdump -Z root -i veth-net-srv -nn -U -s 128 -w "$PCAP" 'tcp port 8080' \
  > "$STATE/tcpdump.log" 2>&1 &
tcpdump_pid=$!
wait_until 5 grep -q 'listening on' "$STATE/tcpdump.log"
echo "$ ip netns exec lab-net-srv tcpdump -Z root -i veth-net-srv -nn -s 128 -w $(basename "$PCAP") 'tcp port 8080'"

ip netns exec lab-net-cli curl -s -o /dev/null --max-time 90 \
  -w 'downloaded %{size_download} bytes in %{time_total}s (%{speed_download} bytes/s)\n' \
  'http://10.204.2.10:8080/blob?size=1000000' > "$STATE/curl.txt" 2>&1 &
curl_pid=$!

step "3. TCP's own view of the connection, from the server side (ss -ti), while it runs"
for i in 1 2 3; do
  sleep 0.7
  echo "--- sample $i"
  ip netns exec lab-net-srv ss -tin state established '( sport = :8080 )' | tail -n +2
done
echo "Look at: rtt (smoothed RTT/variance, ms), retrans (in flight now/total), lost, cwnd (shrinks after loss)."

wait "$curl_pid"
cat "$STATE/curl.txt"
sleep 0.5
kill -INT "$tcpdump_pid" 2>/dev/null
wait "$tcpdump_pid" 2>/dev/null

step "4. Kernel counters in the server's network namespace"
show ip netns exec lab-net-srv nstat -asz TcpOutSegs TcpRetransSegs TcpExtTCPLostRetransmit TcpExtTCPTimeouts
retrans="$(ip netns exec lab-net-srv nstat -asz TcpRetransSegs | awk '$1 == "TcpRetransSegs" {print $2}')"

step "5. Packet analysis of the capture with tshark"
total="$(tshark -r "$PCAP" 2>/dev/null | wc -l)"
ts_retrans="$(tshark -r "$PCAP" -Y 'tcp.analysis.retransmission' 2>/dev/null | wc -l)"
ts_dupack="$(tshark -r "$PCAP" -Y 'tcp.analysis.duplicate_ack' 2>/dev/null | wc -l)"
echo "$ tshark -r $(basename "$PCAP") -Y 'tcp.analysis.retransmission' | wc -l"
echo "packets captured: $total, retransmissions: $ts_retrans, duplicate ACKs: $ts_dupack"
show_sh "tshark -r $PCAP -Y 'tcp.analysis.retransmission' 2>/dev/null | head -5"
show_sh "tshark -r $PCAP -q -z expert 2>/dev/null | head -25"

step "6. Find what is shaping the link: queueing disciplines on every interface"
lossy_ns=""; lossy_iface=""; qline=""
for ns in lab-net-cli lab-net-rtr lab-net-srv; do
  echo "--- namespace $ns"
  ip netns exec "$ns" tc -s qdisc show
  hit="$(ip netns exec "$ns" tc qdisc show | grep -m1 ' netem ')"
  if [[ -n "$hit" ]]; then
    lossy_ns="$ns"; qline="$hit"
    lossy_iface="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' <<<"$hit")"
  fi
done
delay="$(grep -oE 'delay [0-9.]+m?s' <<<"$qline" | awk '{print $2}')"
loss="$(grep -oE 'loss [0-9.]+%' <<<"$qline" | awk '{print $2}')"
echo "netem on $lossy_ns/$lossy_iface: delay $delay, loss $loss. The 'dropped' counter above is netem at work."

finding lossy_ns "$lossy_ns"
finding lossy_iface "$lossy_iface"
finding netem_delay "$delay"
finding netem_loss "$loss"
finding kernel_retransmissions "$([[ ${retrans:-0} -gt 0 ]] && echo yes || echo no)"
finding tshark_retransmissions "$([[ ${ts_retrans:-0} -gt 0 ]] && echo yes || echo no)"
