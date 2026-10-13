# 0006: Grid Signal stores one Firestore document per day and ingests with a Cloud Run Job

**Status:** accepted, Oct 2026 · Project: [gcp-grid-signal](../../projects/gcp-grid-signal)

## Context
EirGrid publishes a reading every 15 minutes: 96 a day. The API needs "latest", "last 24 hours" and "the same times over the last 7 days". The project should cost nothing at rest and stay inside free-tier limits.

## Options for storage
1. One Firestore document per reading. Simple, but a 7-day lookup reads 672 documents, and a busy dashboard would use up the daily free reads quickly.
2. BigQuery. Great for analysis, but heavier than this needs, and streaming inserts cost money.
3. **One document per Dublin day**, holding that day's values as a map. A 7-day lookup is 8 reads, and each ingest run is one merge write.

## Options for ingest
1. An `/ingest` endpoint on the public service, called by Cloud Scheduler with an OIDC token. Works, but puts a write path on a public service.
2. **A Cloud Run Job** started by Cloud Scheduler. Nothing public can trigger a write, the job has its own service account with write access, and the API's account can only read.

## Decision
Day documents plus a Cloud Run Job. The API also caches day documents for 60 seconds.

## Consequences
- Reads and writes stay in the hundreds per day, not thousands.
- Read and write permissions are split across two identities.
- A day document is capped at 1 MiB, far above the ~10 KB a day uses.
- Ad-hoc analysis across months would be easier in BigQuery. A scheduled export could add that later without changing the API.
