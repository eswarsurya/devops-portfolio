# docker-cicd-pipeline

A containerised Python API with a full CI/CD pipeline in GitHub Actions. It goes from lint and tests, to a container smoke test and a Trivy security scan, to a push to GitHub Container Registry, with an optional deploy to EC2 behind a manual approval gate.

![docker-cicd-pipeline](https://github.com/eswarsurya/devops-portfolio/actions/workflows/docker-cicd-pipeline-ci.yml/badge.svg)

## What it shows

| Practice | Where |
|---|---|
| Multi-stage Docker build, slim base, **non-root user**, HEALTHCHECK | `Dockerfile` |
| Lint + format gate (ruff), unit tests (pytest) | `ci-cd.yml` → `test` |
| **Smoke test the real container** before anything is pushed | `ci-cd.yml` → `build` |
| **Vulnerability scan** (Trivy, results in the GitHub Security tab) | `ci-cd.yml` → `build` |
| Images tagged with the **git SHA** for traceable rollbacks | `ci-cd.yml` → `meta` |
| Deploy with **post-deploy health check** and a manual approval gate | `ci-cd.yml` → `deploy` |
| Liveness `/health`, readiness `/ready`, **Prometheus `/metrics`** | `app/main.py` |
| Local stack with Prometheus scraping the API | `docker-compose.yml` |

## Pipeline

```
 git push ──► [test]  ruff lint/format ─► pytest (7 tests)
                 │
                 ▼
             [build] docker build ─► run container ─► curl /health ─► Trivy scan
                 │                                                     │
                 │ main only                                           ▼
                 ▼                                       GitHub Security tab (SARIF)
             push ghcr.io/<you>/docker-cicd-pipeline:<sha> + :latest
                 │
                 ▼
             [deploy] (approval gate) ─► ssh EC2 ─► docker pull/run ─► curl /health
```

## Run it locally

```bash
docker compose up --build
curl localhost:8000/health
curl -X POST localhost:8000/incidents -H 'content-type: application/json' \
     -d '{"title":"checkout API down","severity":1}'
curl localhost:8000/incidents
open http://localhost:9090          # Prometheus → query: http_requests_total
docker compose down
```

Without Docker:

```bash
pip install -r requirements-dev.txt
pytest -q          # 7 passed
uvicorn app.main:app --reload
```

## Turn on the deploy step (optional, free tier)

1. Launch a `t2.micro`/`t3.micro` (Amazon Linux 2023), open port 80 and port 22 (your IP only), and install Docker:
   `sudo dnf install -y docker && sudo systemctl enable --now docker && sudo usermod -aG docker ec2-user`
2. Make the GHCR package public (Package settings → visibility), or run `docker login ghcr.io` on the host.
3. In the repo: **Settings → Secrets → Actions**, add `DEPLOY_HOST`, `DEPLOY_USER` (`ec2-user`), `DEPLOY_SSH_KEY`.
4. **Settings → Environments → production → Required reviewers**: add yourself. Every deploy now waits for your click.

**Teardown:** terminate the instance and delete its security group. GHCR storage for public images is free.

## Using ECR instead of GHCR

Swap the push step for `aws-actions/configure-aws-credentials` (use GitHub **OIDC**, not stored keys) and `aws-actions/amazon-ecr-login`, then push to `<acct>.dkr.ecr.eu-west-1.amazonaws.com/incident-api`. I used GHCR so anyone can fork and run the pipeline without an AWS account.

## What I'd add next

- Deploy to Kubernetes with Helm and Argo CD instead of SSH (GitOps).
- A Postgres backing store, with a readiness check that actually pings the DB.
- A Grafana dashboard for p95 latency from the histogram.
