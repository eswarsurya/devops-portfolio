# jenkins-pipeline

A Jenkins delivery pipeline for the incident-api from [docker-cicd-pipeline](../docker-cicd-pipeline): test, build, scan, push, deploy to staging, approve, deploy to production. Every deploy health-checks the new container and **rolls back automatically** if it fails.

Jenkins itself is configured entirely in code (JCasC), so the whole setup starts with one command and no clicking through setup screens.

![jenkins-pipeline](https://github.com/eswarsurya/devops-portfolio/actions/workflows/jenkins-pipeline-ci.yml/badge.svg)

## The pipeline

```
 Prepare ─► Lint & unit tests ─► Build image ─► Trivy scan ─► Push to registry
                                                                    │
       ┌────────────────────────────────────────────────────────────┘
       ▼
 Deploy to staging ──► Approve (manual) ──► Deploy to production
   │ health check                             │ health check
   └─ fails? roll back staging, stop          └─ fails? roll back production, stop
```

| Stage | What happens |
|---|---|
| Lint and unit tests | Runs `ruff` and `pytest` inside a clean Python container ([ci/test.Dockerfile](ci/test.Dockerfile)). Any failure stops the release. |
| Build image | Builds the app image, tagged `<commit>-<build number>` so every build is traceable. |
| Security scan | Trivy scans the image for HIGH and CRITICAL CVEs. The report is archived on the build. |
| Push to registry | Pushes to a private registry running alongside Jenkins. |
| Deploy to staging | [scripts/deploy.sh](scripts/deploy.sh) replaces the container and polls `/health` for 30 seconds. |
| Approve production | A person clicks **Deploy** in Jenkins. Waits up to an hour. |
| Deploy to production | Same script, same health check, same rollback. |

## Proven in CI, not just written

[The workflow](../../.github/workflows/jenkins-pipeline-ci.yml) starts this Jenkins on a GitHub runner and runs the job twice:

1. **Good release:** passes every stage; staging and production both serve the new version.
2. **Broken release** (`SIMULATE_BAD_RELEASE=true`, an image whose process exits at once): staging's health check fails, staging is **rolled back** to the previous image, the build fails, and **production never changes**. CI checks both containers still run the good image and answer `/health`.

It also validates the Jenkinsfile with Jenkins' own declarative linter, and runs ShellCheck on the scripts.

## Run it yourself

Needs Docker.

```bash
cd projects/jenkins-pipeline
export JENKINS_ADMIN_PASSWORD='pick-a-password'
DOCKER_GID=$(stat -c %g /var/run/docker.sock) docker compose up -d --build
```

Open http://localhost:8080 (user `admin`), run **incident-api**, and approve the production step when it asks. To see the rollback, run it again with **SIMULATE_BAD_RELEASE** ticked.

Clean up:

```bash
docker rm -f incident-api-staging incident-api-production
docker compose down -v
```

## Files

```
Jenkinsfile              the pipeline (declarative)
jenkins/Dockerfile       Jenkins LTS + Docker CLI + plugins
jenkins/plugins.txt      plugin list, installed at image build
jenkins/casc.yaml        Jenkins as code: admin user, security, the job (Job DSL)
docker-compose.yml       Jenkins + a private registry on one network
scripts/deploy.sh        deploy, health-check, roll back
ci/test.Dockerfile       lint and unit tests in a clean container
ci/run-pipeline.sh       trigger a build over the REST API and wait for the result
```

## Design choices

- **Configuration as code.** The admin user, security settings and the job live in `casc.yaml`. A lost Jenkins can be rebuilt from git in minutes, and every change goes through review.
- **Health check, then roll back.** The script records which image was running before the deploy. If the new one doesn't answer `/health` within 30 seconds, it restarts the old one. A bad release costs a failed build, not an outage.
- **Staging before production.** A broken image fails in staging, so production never sees it.
- **Traceable tags.** `<commit>-<build>` tags tie every running container to a commit and a Jenkins build.
- **Approval gate.** Production needs a person. In CI the gate is skipped with `AUTO_APPROVE`, because there is nobody to click.

## Trade-offs and what I'd change for a real team

- **Short downtime during a deploy.** The old container stops before the new one starts. With more time I'd run blue/green: start the new one alongside, switch traffic, then stop the old one.
- **Builds run on the controller.** Fine for one person. A team would add build agents (Docker or Kubernetes) so jobs can't affect Jenkins itself.
- **The Docker socket is shared with Jenkins.** That is root-equivalent on the host. Agents with rootless Docker, or Kaniko or BuildKit, would remove it.
- **The scan is report-only.** Switch Trivy to `--exit-code 1` to block releases with HIGH or CRITICAL findings, once a process exists for handling exceptions.
- **The password comes from an environment variable.** A team would use a secrets manager and SSO.
