output "service_url" {
  description = "Public dashboard and API."
  value       = google_cloud_run_v2_service.api.uri
}

output "image_repository" {
  description = "Where CI pushes images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/grid-signal"
}

output "workload_identity_provider" {
  description = "Set as the GitHub repository variable GCP_WIF_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_service_account" {
  description = "Set as the GitHub repository variable GCP_DEPLOYER_SA."
  value       = google_service_account.deployer.email
}

output "ingest_job" {
  value = google_cloud_run_v2_job.ingest.name
}
