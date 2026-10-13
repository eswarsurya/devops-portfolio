# One document per Dublin day in the "days" collection. The free tier covers this project's reads
# and writes (one write per ingest run, a few cached reads per dashboard view).
resource "google_firestore_database" "default" {
  name                    = "(default)"
  location_id             = var.region
  type                    = "FIRESTORE_NATIVE"
  delete_protection_state = "DELETE_PROTECTION_DISABLED"
  deletion_policy         = "DELETE"
  depends_on              = [google_project_service.this]
}

resource "google_artifact_registry_repository" "images" {
  repository_id = "grid-signal"
  location      = var.region
  format        = "DOCKER"
  description   = "Grid Signal container images"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s" # 30 days
    }
  }
  depends_on = [google_project_service.this]
}
