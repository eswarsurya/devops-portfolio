# Incident-Ready API

A small containerised HTTP service for demonstrating operational engineering fundamentals: health checks, automated tests, container hygiene, and CI.

## Features
- Separate liveness and readiness endpoints.
- Repeatable readiness failure via the simulated DEPENDENCY_STATUS environment variable.
- Version and process uptime endpoint.
- JSON 404 responses.
- Docker image runs as a non-root user and includes a health check.
- GitHub Actions runs tests and builds the image.

## Run locally
Requires Python 3.12+.

    cd projects/incident-ready-api
    python -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt
    pytest -q
    python app.py

Try the endpoints:
- GET http://127.0.0.1:8080/health/live
- GET http://127.0.0.1:8080/health/ready
- GET http://127.0.0.1:8080/api/v1/status

## Reproduce a failure
Stop the app and restart with DEPENDENCY_STATUS=unavailable in the environment. The liveness endpoint should remain healthy while readiness returns HTTP 503. This is a controlled simulation, not a real external dependency check. Restart without the variable to recover.

## Build the container

    docker build -t incident-ready-api:local .
    docker run --rm -p 8080:8080 incident-ready-api:local

## Interview topics
1. Why should liveness and readiness be different?
2. Why does the container run as non-root?
3. How would you replace the simulated dependency with a real database/upstream health check?
4. What additional production controls would you add: timeouts, TLS termination, metrics, tracing, image scanning, deployment approvals, and secrets management?

## Limitations
Educational service only. Dependency status is simulated; uptime resets on restart; there is no authentication, database, distributed tracing, or production SLO. Do not expose publicly without additional controls.

**Evidence status:** source and CI workflow are proposed for review. Record test and deployment results only after running them. Do not describe this as a production deployment.
