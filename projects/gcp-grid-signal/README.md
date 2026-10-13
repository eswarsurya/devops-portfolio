# gcp-grid-signal

**How clean is Ireland's electricity right now, and when is the best time to run heavy work?**

Grid Signal pulls live all-island grid data from EirGrid every 15 minutes (carbon intensity, wind and demand), stores it in Firestore and serves a public dashboard, a JSON API and a README badge from Cloud Run. It also ships a **carbon-aware CI gate**: a GitHub Action that holds heavy, non-urgent jobs until the grid is cleaner.

Everything on Google Cloud is defined in Terraform, deploys from GitHub without a single stored key, scales to zero, and alerts by email if the data goes stale.

![gcp-grid-signal](https://github.com/eswarsurya/devops-portfolio/actions/workflows/gcp-grid-signal-ci.yml/badge.svg)

## Why it's useful

The carbon intensity of Irish electricity swings a lot: low on windy nights, high on calm evenings when gas plants run. Shifting flexible work (nightly builds, load tests, backups, ML training) to cleaner hours cuts its emissions without changing the work itself. This is a real green-software practice, and the same idea a platform team would apply to its own CI.

## Architecture

```
 Cloud Scheduler ──(every 15 min, OAuth as scheduler SA)──► Cloud Run Job: grid-signal-ingest
  "*/15 * * * *" Europe/Dublin                                   │  fetch today's readings from EirGrid
                                                                  ▼  (retries, strict parsing)
                                                        Firestore: days/{YYYY-MM-DD}
                                                                  ▲  one document per day
 Browser / curl / GitHub Actions ──► Cloud Run: grid-signal ──────┘  (reads cached 60 s)
   /  /api/now  /api/history  /api/best-window  /badge.svg  /health
                                         │
 Cloud Monitoring uptime check ──► /health (503 if data > 60 min old) ──► alert email

 GitHub Actions (main only) ──OIDC──► Workload Identity Federation ──► deployer SA
   build ► push to Artifact Registry ► deploy service ► update job ► run job ► check /health
```

| Piece | GCP service | Why |
|---|---|---|
| API and dashboard | Cloud Run service | Scales to zero; public, read-only |
| Ingest | Cloud Run Job + Cloud Scheduler | A job, not a web endpoint, so nothing public can trigger writes |
| Storage | Firestore (native) | One document per day: a 7-day lookup is 8 reads, which keeps it in the free tier |
| Images | Artifact Registry | Cleanup policy keeps the last 5 images and deletes anything over 30 days old |
| CI to GCP | Workload Identity Federation | No service account keys; only `main` of this repo can deploy |
| Alerts | Uptime check + alert policy | One check covers "service down" and "ingest stopped" |
| Cost guard | Billing budget | Emails at 50%, 90% and 100% of the monthly budget |

## API

| Endpoint | Returns |
|---|---|
| `GET /api/now` | Latest intensity (gCO2/kWh), band (low/medium/high), wind, demand, wind share, age |
| `GET /api/history?hours=24` | Readings for the last 1–168 hours |
| `GET /api/best-window?duration_minutes=120&within_hours=24` | Best start time, expected intensity, saving vs now |
| `GET /badge.svg` | A live badge for any README |
| `GET /health` | 200 if the newest reading is under 60 minutes old, otherwise 503 |

**Best window:** EirGrid doesn't publish a carbon forecast, so the estimate is the median of the same 15-minute slots over the last 7 days. Simple, explainable and honest about what it is. A wind forecast would be the next improvement.

## Carbon-aware CI gate

```yaml
- uses: eswarsurya/devops-portfolio/projects/gcp-grid-signal/carbon-gate@main
  with:
    api-url: https://<your-grid-signal-url>
    max-intensity: "250"     # gCO2/kWh
    max-wait-minutes: "120"  # never block delivery for longer than this
- run: ./run-heavy-nightly-job.sh
```

It never stops delivery: if the API can't be reached it continues straight away with a warning, and after the time limit it continues anyway.

## Least privilege

| Identity | Can do |
|---|---|
| `grid-signal-api` | Read Firestore |
| `grid-signal-ingest` | Read and write Firestore |
| `grid-signal-scheduler` | Start the ingest job, nothing else |
| `grid-signal-deployer` | Push to this Artifact Registry repo, update Cloud Run, act as the two runtime accounts |
| GitHub Actions | Become the deployer only from `eswarsurya/devops-portfolio` on `main` |

## How it's tested

| Check | What it proves |
|---|---|
| 24 pytest tests | Parsing (nulls, other regions, unknown fields, bad timestamps), retries, the best-window maths, health and staleness, badge, query limits, ingest backfill |
| `terraform test` (mocked provider) | 15-minute Dublin schedule, scale-to-zero, least-privilege roles, deploy limited to `main` of this repo, budget thresholds |
| Container smoke test | The image starts the way Cloud Run starts it, and reports "no data" correctly |
| Carbon gate test | The gate opens against a fake API |
| Live feed contract (weekday cron) | EirGrid's real endpoint still returns data we can parse, and it's fresh |

## Deploy it (about 20 minutes, in Cloud Shell)

You need a Google Cloud project with billing enabled. With the defaults this is designed to stay inside the free tier: Cloud Run scales to zero, 96 short job runs a day, a few hundred Firestore operations a day. Free-tier limits change, so the budget alert is the real safety net.

1. Open [Cloud Shell](https://shell.cloud.google.com), which has Terraform and gcloud installed.
2. Get the code and fill in your values:
   ```bash
   git clone https://github.com/eswarsurya/devops-portfolio.git
   cd devops-portfolio/projects/gcp-grid-signal/infra
   cp terraform.tfvars.example terraform.tfvars   # set project_id, alert_email, billing_account
   gcloud config set project <your-project-id>
   terraform init && terraform apply
   ```
3. In GitHub, go to **Settings → Secrets and variables → Actions → Variables** and add:
   - `GCP_PROJECT` = your project ID
   - `GCP_WIF_PROVIDER` = the `workload_identity_provider` output
   - `GCP_DEPLOYER_SA` = the `deployer_service_account` output
4. Create an environment called `gcp` under **Settings → Environments** (optionally with yourself as reviewer).
5. Re-run the latest `gcp-grid-signal` workflow on `main`. It builds, deploys, runs the ingest job once, and prints the live URL in the run summary.
6. Load a week of history so the best window works immediately:
   ```bash
   gcloud run jobs execute grid-signal-ingest --region europe-west1 --update-env-vars BACKFILL_DAYS=7 --wait
   ```

**Tear down:** `terraform destroy` in the same folder. Firestore data and images are deleted with it.

## Run it locally

```bash
pip install -r requirements-dev.txt
pytest -q
STORE=memory uvicorn app.main:app --port 8080   # empty in-memory store; ingest needs Firestore
```

## Decisions and limits

- **Day documents instead of one document per reading:** 8 reads for a week instead of 672, so it stays well inside Firestore's free tier even if the dashboard is busy.
- **Unofficial endpoint:** EirGrid's dashboard API is public but undocumented. The parser rejects anything unexpected, and a weekday CI job checks the live feed, so a format change shows up as a red build, not silently wrong numbers.
- **Clock change:** EirGrid times are Dublin local. On the October clock change the repeated hour overwrites itself for one day. Accepted for a 15-minute signal.
- **Public API:** read-only and capped at 2 instances. A real service would add Cloud Armor rate limiting.
- **Live deployment:** the code, infrastructure and tests are complete and pass in CI. A screenshot of the running service goes in `docs/` once it's deployed.

Data: [EirGrid Smart Grid Dashboard](https://www.smartgriddashboard.com/). Not affiliated with EirGrid.
