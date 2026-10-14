# onprem-platform-lab

A small private data centre on one machine, the way a lot of companies still run: their own servers, their own
directory, their own load balancer, no cloud provider. Everything starts with Docker Compose, and GitHub Actions boots
the whole thing on every change and runs end-to-end checks against it.

![onprem-platform-lab](https://github.com/eswarsurya/devops-portfolio/actions/workflows/onprem-platform-lab-ci.yml/badge.svg)

## What's in the data centre

```
  branch office ── WireGuard site-to-site VPN ──┐
                                                ▼
                          ┌──────────── Nginx edge (TLS from ACME / Pebble) ────────────┐
                          │  HTTP→HTTPS, rate limiting, least-conn load balancing,       │
                          │  passive health checks, JSON access logs                     │
                          └───────────────┬──────────────────────┬───────────────────────┘
                                          ▼                      ▼
                                 Apache + PHP (web1)     Apache + PHP (web2)     WordPress; /ops pages need an
                                          │                      │               LDAP login in the "sre" group
                                          └──────────┬───────────┘
                                                     ▼
              MySQL db1  ◀── master-master ──▶  MySQL db2          OpenLDAP (users, groups)
                 │
                 └── replication ──▶ MySQL db3 (read replica, super_read_only)

  ELK: Logstash (Nginx logs) → Elasticsearch ← Metricbeat (MySQL, Nginx, system) ← Heartbeat (uptime)  → Kibana
  Rundeck runbooks: replication health check every minute → error handler pages on failure, recovery notice when healthy
```

| Area | What runs |
|---|---|
| Databases | MySQL 8.4: db1 ↔ db2 master-master with GTIDs (odd and even auto-increment ids so the two never collide), db3 a read-only replica |
| Replication monitoring | A check of every replica's IO thread, SQL thread and lag, run by Rundeck every minute, results indexed in Elasticsearch, alert on failure |
| Directory | OpenLDAP with users and groups; Apache authenticates against it; a script for day-to-day LDAP administration |
| Web tier | Two Apache + PHP nodes serving WordPress, behind Nginx |
| Edge | Nginx: TLS 1.2/1.3, HSTS, HTTP→HTTPS, rate limiting (429), least-connection balancing, passive health checks, static caching, `stub_status` |
| Certificates | Certbot gets the certificate over ACME from Pebble, Let's Encrypt's own test CA, the same HTTP-01 flow as production |
| VPN | WireGuard tunnel between a branch-office gateway and the data-centre gateway, routing the branch into the lab network |
| Logs, metrics, uptime | Elasticsearch, Logstash, Kibana, Metricbeat and Heartbeat (8.15) |
| Runbook automation | Rundeck jobs: replication health check every minute (its error handler pages on-call when a replica breaks; a recovery notice follows when it's healthy again) and an LDAP access audit |
| Security patching | A Log4Shell (CVE-2021-44228) remediation, see [log4j-remediation](log4j-remediation) |

## How it's tested

[`tests/run-checks.sh`](tests/run-checks.sh) runs against the live lab in CI. Every line below is an assertion.

| Check | What it proves |
|---|---|
| Write on db1, write on db2 | Both reach the other primary and the replica; ids don't collide |
| Write to db3 | Refused, even for root |
| Replication health check | All replicas healthy |
| TLS | The certificate Nginx serves was issued over ACME by the Pebble CA; HTTP redirects to HTTPS; HSTS is set |
| WordPress | The installer loads through Nginx, so PHP is talking to MySQL |
| Load balancing | Requests are spread over web1 and web2 |
| LDAP | No login → 401; `alice` (in `sre`) → 200; `bob` (not in `sre`) → refused. A new user gets access only after being added to `sre`, and loses it when removed |
| Rate limiting | A burst of 80 requests gets 429s |
| Failover | With web1 stopped, every request is served by web2 |
| VPN | The branch gateway reaches the data-centre end of the tunnel, and reaches the portal inside the lab network through it |
| Replication alerting | The Rundeck job passes, then **fails when replication on db3 is stopped on purpose**, an alert reaches the alert receiver, and after repair the job passes and a recovery notice follows |
| ELK | Nginx logs arrive through Logstash (429s tagged `rate_limited`); Metricbeat collects MySQL and Nginx metrics; replication results are indexed; Heartbeat reports every service up; Kibana is available |
| Log4j | Trivy flags the vulnerable build for CVE-2021-44228 and finds nothing critical in the fixed one |

## Run it yourself

Needs Docker with Compose, about 8 GB of free memory, and the WireGuard kernel module (`sudo modprobe wireguard`).

```bash
cd projects/onprem-platform-lab
./scripts/render-config.sh --generate   # random passwords in .env, keys and config in ./generated
docker compose up -d --build
./scripts/setup-replication.sh
./scripts/rundeck.sh import
./tests/run-checks.sh
```

Then open Kibana on http://localhost:5601, Rundeck on http://localhost:4440 (user `admin`, password in `.env`), and the
portal on https://localhost:8443 (add `127.0.0.1 portal.dublin-dc.lab` to `/etc/hosts`; the certificate is from the
Pebble test CA, so the browser will warn).

LDAP administration:

```bash
./scripts/ldap-admin.sh add-user carol "Carol Kelly" 'a-strong-password'
./scripts/ldap-admin.sh add-to-group carol sre
./scripts/ldap-admin.sh list-group sre
```

Clean up: `docker compose down -v`.

## Design choices

- **GTID replication with auto-positioning.** Replicas find their place by transaction id, not by binlog file and
  position, which makes re-pointing a replica a one-line change.
- **Master-master with split auto-increment.** db1 hands out odd ids and db2 even ids. That stops key collisions, but
  not conflicting updates to the same row, so in practice only one primary takes writes at a time and the other is a
  hot standby.
- **The replica is read-only for everyone.** `super_read_only` blocks even root, so nothing but replication can make it drift.
- **Alerting from the runbook tool.** The check that a person would run by hand is the same one Rundeck runs every
  minute, and its failure is the alert. The alert receiver stands in for a pager.
- **ACME against Pebble.** The certificate flow is the real one; only the CA is a test CA, because a lab hostname
  can't pass Let's Encrypt's public validation.

## Trade-offs

- **Elasticsearch and Kibana run without security** to keep the lab small. Production needs TLS and authentication.
- **LDAP without TLS, and Apache's LDAP cache turned off** so access changes show immediately. Production uses LDAPS
  and a short cache.
- **Each web node keeps its own WordPress files.** Uploads would need shared storage (NFS) or object storage in a real setup.
- **One machine.** The "servers" are containers, so this proves configuration and behaviour, not hardware or real
  network failures.
- **No automatic database failover.** Promoting db2 is a manual, deliberate step; automating it safely needs a
  tool such as Orchestrator and fencing of the old primary.
