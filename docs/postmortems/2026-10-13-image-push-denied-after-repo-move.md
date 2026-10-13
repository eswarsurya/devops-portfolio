# Image pushes denied after the repository moved

**Date:** 12–13 Oct 2026 · **Projects:** docker-cicd-pipeline, aiops-triage-agent, rail-pulse, llm-gateway · **Impact:** four red CI badges on main; no images published for about 19 hours

## Summary
The portfolio moved to a fresh repository. Lint, tests, builds and smoke tests all passed, but the final step, pushing the image to GitHub Container Registry, was denied for four projects.

## Root cause
Container packages on GHCR have their own access list. The existing packages (`ghcr.io/eswarsurya/<name>`) were linked to the old repository, so the new repository's `GITHUB_TOKEN` had no write access to them.

## Options
1. Grant the new repository write access in each package's settings. Four manual changes, and easy to forget on the next move.
2. Publish under names the new repository creates and owns from its first push.

## Fix (13 Oct)
Option 2: images now publish as `ghcr.io/eswarsurya/devops-portfolio/<name>`. Every reference was updated in the same commit: four workflows, the Kubernetes manifests, the Helm values and the Terraform default. All four workflows passed on the next run.

## Lesson
Registry permissions live outside the repository, so moving code doesn't move them. Namespacing images under the repository name ties ownership to the repo.
