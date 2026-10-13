# 0002: Argo CD pulls from git instead of CI pushing to the cluster

**Status:** accepted, Oct 2026 · Project: [k8s-gitops-platform](../../projects/k8s-gitops-platform)

## Context
The simple way to deploy to Kubernetes is a CI job that runs `helm upgrade` or `kubectl apply`. That job then needs cluster-admin credentials stored in CI, and nothing notices when someone changes the cluster by hand.

## Options
1. CI pushes to the cluster with stored credentials.
2. Flux watches git from inside the cluster.
3. Argo CD watches git from inside the cluster.

## Decision
Argo CD, using the app-of-apps pattern, with automated sync, `prune: true` and `selfHeal: true`.

- Pull-based: no cluster credentials live in CI.
- Git is the source of truth. A manual change is reverted automatically, and removing a manifest from git removes the resource.
- Argo CD's UI shows sync and health per application, which helps when explaining the setup and when debugging. Flux would also work; the deciding factor was the UI and the app-of-apps bootstrap.

## Consequences
- Rolling back means reverting a commit, which leaves an audit trail.
- Emergency hotfixes also have to go through git. That's slower in a crisis, but nothing drifts.
- Image updates still need a step that writes the new tag to git (Argo CD Image Updater, or a CI commit). Listed as a next step in the project README.
