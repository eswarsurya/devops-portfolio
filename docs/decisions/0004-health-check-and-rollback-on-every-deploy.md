# 0004: Every deploy health-checks and rolls back on its own

**Status:** accepted, Oct 2026 · Project: [jenkins-pipeline](../../projects/jenkins-pipeline)

## Context
A release can pass every test and still fail to start: a missing environment variable, a bad command, a dependency that only breaks at runtime. Without a check after deploying, the first sign is users seeing errors.

## Decision
`scripts/deploy.sh` records which image is running, starts the new one, and polls `/health` for 30 seconds. If it never answers, the script restarts the previous image and fails the build. Staging always deploys first, and production needs a manual approval.

## Consequences
- A bad release costs a failed build, not an outage. CI proves this on every change by deploying a deliberately broken image and checking that staging is rolled back and production never changes.
- There is a short gap while containers are swapped. Blue/green (start the new one alongside, switch traffic, then stop the old one) would remove it, at the cost of a proxy in front.
- `/health` only proves the process is up. A stronger check would call `/ready` and a real endpoint.
