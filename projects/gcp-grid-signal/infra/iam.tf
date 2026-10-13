# One identity per job, each with only what it needs.

resource "google_service_account" "api" {
  account_id   = "grid-signal-api"
  display_name = "Grid Signal API (reads Firestore)"
}

resource "google_service_account" "ingest" {
  account_id   = "grid-signal-ingest"
  display_name = "Grid Signal ingest job (writes Firestore)"
}

resource "google_service_account" "scheduler" {
  account_id   = "grid-signal-scheduler"
  display_name = "Cloud Scheduler: starts the ingest job"
}

resource "google_service_account" "deployer" {
  account_id   = "grid-signal-deployer"
  display_name = "GitHub Actions deployer (keyless, via Workload Identity Federation)"
}

resource "google_project_iam_member" "api_reads" {
  project = var.project_id
  role    = "roles/datastore.viewer"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "ingest_writes" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.ingest.email}"
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_runs_ingest" {
  name     = google_cloud_run_v2_job.ingest.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

# Deployer: push images to this one repository, and update Cloud Run (running as the two runtime accounts).
resource "google_artifact_registry_repository_iam_member" "deployer_pushes" {
  repository = google_artifact_registry_repository.images.name
  location   = var.region
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_project_iam_member" "deployer_run" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_service_account_iam_member" "deployer_acts_as_runtime" {
  for_each           = { api = google_service_account.api.name, ingest = google_service_account.ingest.name }
  service_account_id = each.value
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

# Keyless CI: GitHub's OIDC token is exchanged for short-lived credentials. No JSON key exists anywhere.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }
  # Only workflows from this repository's main branch can get credentials.
  attribute_condition = "assertion.repository == '${var.github_repo}' && assertion.ref == 'refs/heads/main'"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_impersonates_deployer" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
