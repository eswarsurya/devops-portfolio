# go-replicated-kv

A small distributed key-value store written in Go, run the way an SRE team would run it. Three nodes each hold a full copy of the data. Reads and writes need a quorum of two, so the cluster keeps working with one node down and refuses (with a 503) rather than guess when two are down. A restarted node replays its write-ahead log and then catches up on what it missed.

Around the service there is an SLO with burn-rate alerts, a load test and capacity plan, an error budget policy, a runbook, and a game day that CI runs on every change: it kills nodes, checks the page fires, recovers the cluster and checks the page clears.

Standard library only: no third-party Go modules. The Prometheus metrics format is written by hand.

![go-replicated-kv](https://github.com/eswarsurya/devops-portfolio/actions/workflows/go-replicated-kv-ci.yml/badge.svg)

## Architecture

```
                 clients (any node can take any request)
                  │                 │                 │
          :8080 client API   :8080 client API   :8080 client API
           /kv /healthz       /kv /healthz       /kv /healthz
           /readyz /metrics   /readyz /metrics   /readyz /metrics
          ┌──────┴─────┐     ┌──────┴─────┐     ┌──────┴─────┐
          │    kv1     │     │    kv2     │     │    kv3     │
          │ coordinator│◄───►│ coordinator│◄───►│ coordinator│
          │ map + WAL  │:7070│ map + WAL  │:7070│ map + WAL  │
          └──────┬─────┘     └──────┬─────┘     └──────┬─────┘
                 │  peer API: replicate, fetch, digest, ping  │
                 └─────────────────────┬──────────────────────┘
                                       │ scrape /metrics every 5s
                                 Prometheus ── SLI recording rules
                                       │        burn-rate alerts
                                       ▼
                           Alerts API (checked by the game day)
```

**Write** (`PUT /kv/{key}` on any node):

1. The node that receives it becomes the coordinator. It stamps a version: a hybrid clock timestamp (wall-clock microseconds that never go backwards) plus its own node ID.
2. It appends the record to its WAL, fsyncs, and updates its in-memory map.
3. It sends the record to both peers in parallel, with a timeout, and replies once one peer has acknowledged (W=2 including itself). The third copy keeps going in the background.
4. If fewer than 2 replicas confirm in time, the client gets **503**.

**Read** (`GET /kv/{key}`): the coordinator takes its own copy and asks both peers. When 2 answers are in (R=2), it returns the newest version. Any replica that answered with an older copy, or none, gets the newest one written back (**read repair**).

**Anti-entropy:** every node asks each peer for a digest (key → version) every few seconds and at startup, and pulls any key where the peer is newer. That is how a node that was down catches up on keys nobody reads.

**Storage:** each record is appended to `wal.log` as `length | CRC-32C | JSON`. On startup the log is replayed. A half-written last entry (crash mid-write) fails its checksum and is cut off. If the log holds old versions of keys, it is compacted into a new file that is fsynced and renamed into place.

## API

| Method and path | Port | What it does |
|---|---|---|
| `PUT /kv/{key}` | 8080 | Body is the value (up to 1 MiB). 200 with the version, 503 if no write quorum. |
| `GET /kv/{key}` | 8080 | 200 with the raw value and an `X-KV-Version` header, 404 if missing or deleted, 503 if no read quorum. |
| `DELETE /kv/{key}` | 8080 | Writes a tombstone through the same quorum path. |
| `GET /healthz` | 8080 | Liveness: the process is up. Stays 200 when quorum is lost, so an orchestrator does not restart healthy nodes during a network problem. |
| `GET /readyz` | 8080 | Readiness: 200 only if enough peers answered the last ping to form a quorum. |
| `GET /metrics` | 8080 | Prometheus text format. |
| `/internal/kv/{key}`, `/internal/digest`, `/internal/ping` | 7070 | Peer replication API, on its own port so it can be firewalled from clients. |
| `/debug/pprof/` | 6060 | Go profiler, bound to localhost by default. |

Keys are 1 to 200 characters from `A-Z a-z 0-9 . _ : -`.

Metrics include `kv_http_requests_total{route,method,code}`, `kv_http_request_duration_seconds` (histogram), `kv_replication_failures_total{peer,op}`, `kv_quorum_failures_total{op}`, `kv_read_repairs_total{target}`, `kv_antientropy_repaired_keys_total`, `kv_peer_up{peer}`, `kv_ready` and `kv_records`. Logs are JSON (`log/slog`). SIGTERM stops new requests, lets in-flight ones finish, stops the background loops and closes the WAL.

## Consistency model, and its limits

With N=3, W=2, R=2, every read quorum overlaps every write quorum (W + R > N). So once a write has been acknowledged, a later read sees it or something newer, as long as no other write to the same key is racing it and the nodes' clocks are roughly in step.

What it does **not** give you, on purpose or for lack of time:

- **Concurrent writes can be lost.** Two clients writing the same key at the same moment through different nodes both get 200. Last writer wins by (timestamp, node ID), so one value silently replaces the other. Systems that cannot accept this use vector clocks and return both versions, or a consensus protocol like Raft.
- **Not linearizable.** Read repair happens after the reply, and there is no single order of operations agreed by all nodes. Two reads at the same moment can return different values while a write is in flight.
- **A 503 on a write means "unknown", not "failed".** The coordinator writes its own copy first and does not roll back. The game day checks this: a write that got 503 while kv2 and kv3 were down shows up on kv2 after recovery, copied by anti-entropy. Clients should treat a 503 on a write as "maybe" and retry with the same value.
- **Clock skew matters.** Versions use wall-clock time. A node whose clock runs minutes ahead wins every conflict for those minutes. The hybrid clock only stops time going backwards on one node; it does not fix skew between nodes.
- **Fixed membership.** The peer list is set at startup. Adding or replacing a node means changing config and restarting. There is no rebalancing, no sharding and no hinted handoff.
- **Tombstones are kept forever.** Deleted keys still take a WAL entry. A real system would remove tombstones after every replica has seen them.

## How it is tested

Each claim in this table is checked by a CI job in [go-replicated-kv-ci.yml](../../.github/workflows/go-replicated-kv-ci.yml).

| Claim | How it is proven | CI job |
|---|---|---|
| Versions order correctly; ties break the same way on every node; the clock never goes backwards | Table-driven unit tests in `internal/store` | `test` |
| Last-writer-wins, tombstones beat older values | `TestApplyLastWriterWins`, `TestDeleteWinsOverOlderValue` | `test` |
| Acknowledged writes survive a restart; a torn or corrupt WAL tail is cut off and appends continue after it; compaction keeps the newest values | WAL tests with real files, including a half-written frame and a flipped bit | `test` |
| Writes succeed with one peer down or stalled, fail with 503 without a quorum, and a stalled peer costs at most the timeout | `TestWriteQuorum` with fake peers that refuse or hang | `test` |
| Reads return the newest copy and repair stale replicas, including late ones | `TestReadQuorumAndRepair` | `test` |
| Concurrent writers on two nodes converge on the same value | `TestConcurrentWritersConvergeOnSameValue` | `test` |
| A real 3-node cluster over HTTP: one node down keeps working; two down returns 503 and `/readyz` fails while `/healthz` stays up; restarted nodes replay the WAL and catch up through anti-entropy | `TestFailureAndRecovery` (three nodes on loopback sockets, nodes stopped and restarted) | `test` |
| Read repair alone fixes a stale node | `TestReadRepairFixesStaleReplica` (anti-entropy off) | `test` |
| No data races | All tests run with `-race` | `test` |
| Hand-written metrics match the Prometheus text format | Golden-output test | `test` |
| Burn-rate alerts fire for the right error rates and stay quiet otherwise | `promtool test rules` on 6 scenarios | `slo-rules` |
| The image runs as a non-root user | `docker image inspect` | `load-test` |
| The 3-node cluster meets the SLO at 200 req/s for 60s (p95 < 100 ms, errors < 0.1%) | k6 thresholds; the job fails if they are missed | `load-test` |
| Capacity curve for 3 nodes and for 1 node, and where CPU goes | k6 step test plus a pprof CPU profile; tables in the job summary | `load-test` |
| Losing one node pages nobody; losing two pages within minutes; a write that got 503 still spreads after recovery; recovery brings a missed write back to the restarted node; the page clears on its own | Game day against the compose cluster with Prometheus, checking the alerts API | `game-day` |
| SIGTERM drains and closes the WAL cleanly; logs are JSON | After the game day, `docker compose stop` and a check for the `kvnode stopped cleanly` JSON log line | `game-day` |
| pprof works under load | A 30-second CPU profile is fetched from kv1 during the step test | `load-test` |

The load test numbers and the game day timeline are written to the job summary of each run. [docs/capacity-plan.md](docs/capacity-plan.md) and the [game day postmortem](docs/incidents/postmortem-gameday-quorum-loss.md) quote one run as an example.

## Run it yourself

Go 1.24 only:

```bash
go test -race ./...
go test -run '^$' -bench . ./...

go run ./cmd/kvnode -node-id kv1 -listen :8081 -peer-listen :7071 -data-dir /tmp/kv1 \
  -peers kv2=http://localhost:7072,kv3=http://localhost:7073 &
go run ./cmd/kvnode -node-id kv2 -listen :8082 -peer-listen :7072 -admin-listen '' -data-dir /tmp/kv2 \
  -peers kv1=http://localhost:7071,kv3=http://localhost:7073 &
go run ./cmd/kvnode -node-id kv3 -listen :8083 -peer-listen :7073 -admin-listen '' -data-dir /tmp/kv3 \
  -peers kv1=http://localhost:7071,kv2=http://localhost:7072 &

curl -X PUT --data-binary hello localhost:8081/kv/greeting
curl -i localhost:8083/kv/greeting
```

With Docker (3 nodes plus Prometheus with the SLO rules):

```bash
docker build -t go-replicated-kv:local .
docker compose up -d
open http://localhost:9090/alerts

STEADY_RATE=200 scripts/loadtest.sh my-run steady   # k6 in a container
scripts/gameday.sh                                    # about 10 minutes
docker compose down -v
```

Every flag has an environment variable (`kvnode -help`), for example `KV_PEERS`, `KV_W`, `KV_R`, `KV_SYNC`, `KV_PEER_TIMEOUT`, `KV_ANTI_ENTROPY_INTERVAL`.

## Files

```
cmd/kvnode/              flags and env, three HTTP servers, graceful shutdown
internal/store/          versions, hybrid clock, WAL with checksums, compaction
internal/cluster/        quorum reads and writes, read repair, anti-entropy, peer client
internal/server/         HTTP handlers, metrics middleware, 3-node integration tests
internal/metrics/        Prometheus counters, gauges, histograms (text format)
slo/                     SLO definition, recording and alert rules, promtool tests
loadtest/kv.js           k6 script: steady, step and soak modes
scripts/                 load test, CPU profile and game day (used by CI)
docs/                    capacity plan, error budget policy, runbook, postmortem
```

## Design choices

- **Leaderless quorums instead of Raft.** Any node can serve any request and there is no election to wait for when a node dies. The cost is weaker consistency (above). For a cache-like or session store that trade is often right. For anything where a lost update is a bug, I would use Raft (etcd's library, or etcd itself).
- **Write locally first, then fan out.** The coordinator's own copy is one of the W acknowledgements, so a write needs one network round trip, not two.
- **Detach replication from the client's context.** If a client hangs up after quorum, the background copies still finish, bounded by the peer timeout. Otherwise a cancelled request could leave one replica behind for no reason.
- **Checksummed WAL with truncation on replay.** A crash mid-append leaves a partial frame. The CRC finds it, replay stops there, and the file is truncated so the next append starts clean. Without the checksum a corrupt tail would either crash the node on start or be read as garbage.
- **Liveness and readiness are different.** `/healthz` says the process works; `/readyz` says it can serve. Mixing them up makes an orchestrator restart every node during a network split, which turns a partial outage into a full one.
- **Page on symptoms, ticket on causes.** Burn-rate alerts page because users feel them. `KVNodeDown` is a ticket because the quorum absorbs it, and the game day checks exactly that.
- **Fixed metric labels.** Requests are labelled by route name, never by URL, so the number of time series does not grow with the number of keys. A test checks a key never appears in `/metrics`.
- **Standard library only.** No supply chain to audit and nothing to download at build time. The price is a hand-written metrics package, about 300 lines with a golden-output test.

## Trade-offs and what I would do next

- **Group commit.** One fsync per write, with the store lock held, limits write throughput per node. Batching concurrent writes into one fsync is the first change I would make.
- **Hinted handoff.** Today a node that was down only catches up through anti-entropy or read repair. Storing missed writes for it on a peer would make catch-up faster and cheaper.
- **Merkle-tree anti-entropy.** The digest sends every key's version on every pass. Fine for thousands of keys, wasteful for millions.
- **Client-side SLI.** Requests to a dead node never reach the server's counters. A load balancer or client library metric would close that gap.
- **Kubernetes.** A StatefulSet with a headless Service gives stable names (`kv-0.kv`, `kv-1.kv`) for the peer list, a PodDisruptionBudget of `maxUnavailable: 1` matches the quorum, and `/readyz` keeps traffic off a node that cannot reach quorum.
- **mTLS between peers.** The peer API trusts anything that can reach port 7070. It should require client certificates.
