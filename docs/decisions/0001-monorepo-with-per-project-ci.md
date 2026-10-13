# 0001: One repository, one CI workflow per project

**Status:** accepted, Oct 2026

## Context
The portfolio has eleven small projects. As separate repositories, a reviewer has to open eleven links, and shared settings (secret scanning, CI log diagnosis) would be copied eleven times.

## Decision
Keep every project under `projects/<name>/` in one repository. Each project gets its own workflow, `.github/workflows/<name>-ci.yml`, with a `paths:` filter so it only runs when that project (or its workflow) changes.

## Consequences
- One place to review, one README index, one set of repo-wide tools (gitleaks config, CI Log Doctor).
- A change to one project doesn't run or break the others' CI.
- Each project stays self-contained (own README, dependencies and Dockerfile), so it could be split out later.
- Cost: workflows must set `working-directory`, and a change to a shared file has to list every workflow it affects.
