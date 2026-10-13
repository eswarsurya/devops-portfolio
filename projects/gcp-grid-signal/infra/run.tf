resource "google_cloud_run_v2_service" "api" {
  name                = "grid-signal"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.api.email
    scaling {
      min_instance_count = 0 # scale to zero: no traffic, no cost
      max_instance_count = 2 # caps cost if someone hammers the public URL
    }
    containers {
      image = var.image
      env {
        name  = "STORE"
        value = "firestore"
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }
    }
  }

  # CI deploys new images; Terraform owns everything else.
  lifecycle {
    ignore_changes = [template[0].containers[0].image, client, client_version]
  }
  depends_on = [google_project_service.this]
}

# Public, read-only dashboard and API.
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_job" "ingest" {
  name                = "grid-signal-ingest"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1
    template {
      service_account = google_service_account.ingest.email
      max_retries     = 1
      timeout         = "120s"
      containers {
        image   = var.image
        command = ["python", "-m", "app.ingest"]
        env {
          name  = "STORE"
          value = "firestore"
        }
        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].template[0].containers[0].image, client, client_version]
  }
  depends_on = [google_project_service.this]
}

resource "google_cloud_scheduler_job" "ingest" {
  name             = "grid-signal-ingest"
  region           = var.region
  schedule         = var.schedule
  time_zone        = "Europe/Dublin"
  attempt_deadline = "180s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.ingest.id}:run"
    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
  depends_on = [google_project_service.this]
}
