# Runs with `terraform test`: plans against a mocked Google provider, so no GCP account is needed.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
}

variables {
  project_id  = "grid-signal-test"
  alert_email = "alerts@example.com"
}

run "ingest_runs_every_15_minutes_dublin_time" {
  command = plan
  assert {
    condition     = google_cloud_scheduler_job.ingest.schedule == "*/15 * * * *" && google_cloud_scheduler_job.ingest.time_zone == "Europe/Dublin"
    error_message = "ingest should run every 15 minutes on Dublin time"
  }
}

run "api_scales_to_zero_and_is_capped" {
  command = plan
  assert {
    condition     = google_cloud_run_v2_service.api.template[0].scaling[0].min_instance_count == 0
    error_message = "the API must scale to zero to stay in the free tier"
  }
  assert {
    condition     = google_cloud_run_v2_service.api.template[0].scaling[0].max_instance_count <= 2
    error_message = "max instances caps the cost of a traffic spike"
  }
}

run "least_privilege_roles" {
  command = plan
  assert {
    condition     = google_project_iam_member.api_reads.role == "roles/datastore.viewer"
    error_message = "the public API must only read Firestore"
  }
  assert {
    condition     = google_project_iam_member.ingest_writes.role == "roles/datastore.user"
    error_message = "only the ingest job writes Firestore"
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.deployer_pushes.role == "roles/artifactregistry.writer"
    error_message = "the deployer can push images to its own repository only"
  }
}

run "only_main_branch_of_this_repo_can_deploy" {
  command = plan
  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.repository == 'eswarsurya/devops-portfolio'")
    error_message = "WIF must be limited to this repository"
  }
  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "refs/heads/main")
    error_message = "WIF must be limited to the main branch"
  }
}

run "budget_is_optional" {
  command = plan
  assert {
    condition     = length(google_billing_budget.monthly) == 0
    error_message = "no billing account given, so no budget resource"
  }
}

run "budget_alerts_at_50_90_100_percent" {
  command = plan
  variables {
    billing_account = "AAAAAA-BBBBBB-CCCCCC"
  }
  assert {
    condition     = length(google_billing_budget.monthly) == 1
    error_message = "a billing account should create the budget"
  }
  assert {
    condition     = [for r in google_billing_budget.monthly[0].threshold_rules : r.threshold_percent] == [0.5, 0.9, 1.0]
    error_message = "budget should alert at 50%, 90% and 100%"
  }
}
