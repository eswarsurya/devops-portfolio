# Capacity plan

How I size this service, and the numbers CI measured for it. The method is the point. The numbers come from a GitHub-hosted runner, where the load generator and all three nodes share one small VM, so they are a floor for comparing changes, not a promise about production hardware.

## Method

1. **Fix the target first.** Capacity means "requests per second we can serve *while meeting the SLO*", not the point where the service falls over. Here that is p95 < 100 ms and fewer than 0.1% errors (see [slo/README.md](../slo/README.md)). I also want p99 well under the 100 ms line, so there is room left for a bad day.
2. **Use a realistic mix.** The k6 script ([loadtest/kv.js](../loadtest/kv.js)) sends 80% reads and 20% writes of 128-byte values, spread over 1,000 keys and all three nodes. Every key is written once in `setup()`, so reads find data.
3. **Step the load up.** The step test runs a fixed arrival rate for 20 seconds per step (250, 500, 1,000, 2,000, 4,000 req/s). A fixed arrival rate matters: if the service slows down, k6 keeps sending at the planned rate and counts what it could not send as *dropped*. A closed loop (N users in a loop) would quietly send less and hide the problem.
4. **Find the knee.** For each step compare achieved req/s with the target, and watch p95/p99. The usable capacity is the highest step where achieved ≈ target, nothing is dropped, and p99 is still comfortably inside the SLO.
5. **Compare with one node.** The same step test runs against a single node with W=1, R=1 (no replication). The gap between the two is the cost of replication.
6. **Find the bottleneck, do not guess it.** CI captures a 30-second CPU profile from `kv1` (`/debug/pprof/profile`) in the middle of the step test and prints the top functions to the job summary.
7. **Plan with headroom.** Run at no more than 50% of the measured capacity, so that losing one node (which shifts its traffic to the other two) still leaves the survivors under about 75%.

## Where the time goes

Each write does this:

- the coordinator appends to its own WAL and **fsyncs** before replying (`KV_SYNC=true`)
- it sends the record to both peers in parallel over HTTP; each peer also appends and fsyncs
- it replies after the first peer acknowledges (W=2)

Each read asks two peers in parallel and waits for the first answer (R=2, the local copy counts as one).

So a write costs three fsyncs and two HTTP round trips across the cluster, and a read costs up to two HTTP round trips. The store holds its lock during the WAL append and fsync, so writes on one node are serialised by the disk. The benchmark `BenchmarkApplyWALFsync` measures that cost on its own.

## Results from CI

Example from CI run [38609373029](https://github.com/eswarsurya/devops-portfolio/actions/runs/38609373029) on a GitHub-hosted `ubuntu-latest` runner (k6, three nodes and the Docker network all on one VM, `KV_SYNC=true`). Every run writes its own tables to the job summary, and they move from run to run.

**3 nodes, W=2, R=2, step test (20 s per step):**

| target req/s | achieved req/s | p50 ms | p95 ms | p99 ms | errors | dropped |
|---:|---:|---:|---:|---:|---:|---:|
| 250 | 250.1 | 0.42 | 0.95 | 1.19 | 0% | 0 |
| 500 | 500.1 | 0.40 | 0.91 | 1.13 | 0% | 0 |
| 1,000 | 1,000.0 | 0.40 | 0.93 | 1.25 | 0% | 0 |
| 2,000 | 2,000.0 | 0.44 | 1.10 | 1.76 | 0% | 0 |
| 4,000 | 3,992.9 | 0.85 | 5.17 | 12.03 | 0% | 142 |

**1 node, W=1, R=1 (no replication), same steps:**

| target req/s | achieved req/s | p50 ms | p95 ms | p99 ms | errors | dropped |
|---:|---:|---:|---:|---:|---:|---:|
| 250 | 250.1 | 0.19 | 0.48 | 0.61 | 0% | 0 |
| 500 | 500.0 | 0.19 | 0.45 | 0.56 | 0% | 0 |
| 1,000 | 1,000.0 | 0.19 | 0.47 | 0.66 | 0% | 0 |
| 2,000 | 2,000.0 | 0.19 | 0.52 | 0.75 | 0% | 0 |
| 4,000 | 4,000.3 | 0.22 | 0.68 | 1.33 | 0% | 0 |

**Steady 200 req/s for 60 s on 3 nodes:** p95 0.98 ms, p99 1.21 ms, 0% errors. The SLO thresholds passed (this step fails the job if they do not).

What I read from this run:

- **The knee for 3 nodes is between 2,000 and 4,000 req/s.** At 2,000 everything is flat. At 4,000 k6 could not send 142 requests on time, and p99 grew about 7x. So on this runner I would call the cluster's capacity **C ≈ 2,000 req/s** with the SLO met by a wide margin. The step between 2,000 and 4,000 is too coarse to say more; a finer step test is the next thing to run.
- **Replication roughly doubles latency** (p50 0.19 ms on one node, about 0.4 ms on three) and moves the knee down. That is the price of the extra HTTP round trip and the peers' fsyncs. Even so, p99 at 4,000 req/s (12 ms) is far inside the 100 ms SLO; the dropped requests show saturation before latency does.
- **The CPU profile of kv1 points at system calls, not at my code.** About 35% of sampled CPU was in `syscall.Syscall6` (network writes, WAL writes and fsync), and a large share in the Go scheduler and `futex`, which is goroutines waiting and waking. The coordinator's own fan-out code was about 11% cumulative. The bottleneck is I/O and the shared machine, so the next gains come from fewer syscalls per request (group commit, batching replication) rather than optimising Go code.

On a shared runner, k6 competes with the nodes for CPU, so these numbers are a lower bound.

## Using the numbers

Example, with made-up demand so the arithmetic is clear: suppose clients need **6,000 req/s** at peak, with the same read/write mix.

- From the step test, take the highest step that met the SLO with no drops as the cluster's capacity, **C**. In the run above, C ≈ 2,000 req/s.
- Usable capacity per cluster at 50% target utilisation is **C / 2**, so about 1,000 req/s.
- Clusters needed = ceil(6,000 / 1,000) = **6 three-node clusters** on hardware like the CI runner. Measured again on the real hardware, the same formula gives the real answer.

This design does not scale out by adding nodes to one cluster: every node stores every key and every write goes to every node, so more nodes add durability, not throughput. To scale out you would **shard**: run several 3-node clusters and route each key to one of them by a hash of the key. The calculation above is then the number of shards.

## What would change the numbers

- **fsync per write.** With `KV_SYNC=false` writes get much cheaper but an acknowledged write can be lost if the host loses power. Group commit (batch several writes into one fsync) is the usual middle ground and the first thing I would build.
- **Real hardware.** Separate machines for each node and the load generator, with local NVMe, would raise the numbers a lot. The method stays the same.
- **Value size and key count.** The test uses small values and a working set that fits in memory. Large values make the WAL and the network the limit sooner.
- **The anti-entropy digest.** Every pass sends a node's full key list. That is fine for thousands of keys and wasteful for millions; Merkle trees would fix it.

## Reproduce

```bash
docker build -t go-replicated-kv:local .
docker compose up -d kv1 kv2 kv3
STEPS=250,500,1000,2000,4000 STEP_SECONDS=20 scripts/loadtest.sh cluster-step step
STEADY_RATE=200 STEADY_SECONDS=60 scripts/loadtest.sh cluster-steady steady
scripts/profile.sh kv1 30 kv1-cpu.pb.gz     # run during a step test, in a second terminal
```
