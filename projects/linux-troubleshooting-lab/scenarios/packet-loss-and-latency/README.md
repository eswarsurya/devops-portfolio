# Packet loss and latency on the path

**Reported symptom:** "Downloads from files-api are slow and sometimes stall. The server isn't busy."

## Topology

```
lab-net-cli 10.204.1.10 <--> [10.204.1.1  lab-net-rtr  10.204.2.1] <--> 10.204.2.10 lab-net-srv (files-api :8080)
                       veth-rtr-cli                 veth-rtr-srv
```

Three network namespaces: a client, a router with IP forwarding on, and a server.

## What `break.sh` does

Adds a `netem` queueing discipline to the router's interface towards the client:

```
tc qdisc add dev veth-rtr-cli root netem delay 40ms loss 5%
```

Every packet leaving that interface waits 40 ms, and 5% are dropped. This is how you simulate a bad link, a congested hop or a flaky Wi-Fi network.

## Investigate

1. **Loss and latency, end to end and per hop.** `ping -c 30 -i 0.2 -q` to the server, then to the first hop. One CI run:
   ```
   30 packets transmitted, 27 received, 10% packet loss
   rtt min/avg/max/mdev = 40.033/40.069/40.142/0.019 ms        # to the server
   15 packets transmitted, 14 received, 6.66667% packet loss
   rtt min/avg/max/mdev = 40.029/40.062/40.082/0.012 ms        # to the router
   ```
   Two namespaces on one machine should answer in well under 1 ms. The first hop is already slow and lossy, so the problem is on the client-router link. (The loss figure varies run to run; with 5% random loss, 30 pings is a small sample.)
2. **TCP's view.** While a 1 MB download runs, `ss -tin` on the server shows the connection's internals. A CI sample:
   ```
   rtt:41.365/2.482 ... cwnd:5 ssthresh:5 ... unacked:11 retrans:2/22 lost:2 sacked:6
   ```
   `retrans:2/22` = 2 segments being retransmitted now, 22 so far. `cwnd` dropped to 5 segments because TCP backs off after loss. That, not the server, is why the download is slow: 1 MB took 4.3 s in that run, and 0.001 s after the fix.
3. **Kernel counters.** `nstat -asz TcpRetransSegs ...` in the server's namespace (counters are per network namespace). One CI run: `TcpOutSegs 700`, `TcpRetransSegs 44`.
4. **The capture.** `tcpdump -s 128 -w packet-loss-and-latency.pcap` on the server during the download, then:
   ```
   tshark -r packet-loss-and-latency.pcap -Y 'tcp.analysis.retransmission' | wc -l
   ```
   One CI run found 35 retransmissions and 62 duplicate ACKs in 655 packets. `tshark -q -z expert` summarises the same (fast retransmissions, duplicate ACKs). The pcap is uploaded as a CI artifact for Wireshark.
5. **Find what shapes the link.** `tc -s qdisc show` in each namespace. Only the router has a non-default qdisc:
   ```
   qdisc netem 8001: dev veth-rtr-cli root refcnt 5 limit 1000 delay 40ms loss 5%
    Sent 1052335 bytes 761 pkt (dropped 32, overlimits 0 requeues 0)
   ```
   The `dropped` counter is netem doing its job. On real hardware you would look at `ip -s link` (errors, drops), `ethtool -S` (CRC errors), and the switch or cloud side.

## Root cause

A lossy, slow link between the client and the router (here, injected with netem).

## Fix

`fix.sh` deletes the qdisc. After that CI measured 0% loss over 20 pings, an average RTT of 0.024 ms, and the 1 MB download completes in about a millisecond.

## Prevention

- Measure loss and latency per hop continuously (`mtr`, blackbox probes, cloud network metrics), not only when users complain.
- Alert on the TCP retransmission rate (`node_netstat_Tcp_RetransSegs` in node_exporter) relative to segments sent.
- Test your services under bad network conditions on purpose; netem is the standard tool for it.

## What CI checks

After `break.sh`, ping across the router shows a high RTT (above 10 ms). `diagnose.sh` must find the namespace and interface carrying netem, its delay (40 ms) and loss (5%), at least one retransmission in the kernel counters, and at least one `tcp.analysis.retransmission` in the tshark analysis of the capture. After the fix, ping shows 0% loss and an average RTT under 10 ms, and the 1 MB download succeeds.

## Interview questions this covers

- **Why does 1% packet loss hurt throughput so much?** TCP treats loss as congestion and halves (CUBIC: reduces) its window. Throughput falls roughly with 1/sqrt(loss) and with RTT (the Mathis formula).
- **How do you tell loss from latency in a capture?** Retransmissions and duplicate ACKs mean loss. Big gaps between a segment and its ACK with no retransmits mean latency.
- **What is a duplicate ACK and a fast retransmit?** The receiver repeats its last ACK when a segment is missing. After three duplicate ACKs the sender resends without waiting for the timeout.
- **What are `cwnd` and `rto` in `ss -ti`?** The congestion window (how much the sender may have in flight) and the retransmission timeout.
- **How would you reproduce a customer's bad network?** `tc qdisc ... netem delay/loss/reorder/duplicate`, often with `ifb` to shape ingress too.
