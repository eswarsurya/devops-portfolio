variable "project_id" {
  description = "GCP project to deploy into."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, Scheduler, Firestore and Artifact Registry. europe-west1 (Belgium) is the closest low-cost region to Ireland."
  type        = string
  default     = "europe-west1"
}

variable "github_repo" {
  description = "owner/name of the only GitHub repository allowed to deploy, via Workload Identity Federation."
  type        = string
  default     = "eswarsurya/devops-portfolio"
}

variable "image" {
  description = "Container image for the first apply. CI deploys new images afterwards, so Terraform ignores later changes."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "schedule" {
  description = "How often the ingest job runs (cron, Europe/Dublin). EirGrid publishes every 15 minutes."
  type        = string
  default     = "*/15 * * * *"
}

variable "alert_email" {
  description = "Email for uptime and budget alerts. Empty disables the email channel."
  type        = string
  default     = ""
}

variable "billing_account" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX) for the budget alert. Empty skips the budget."
  type        = string
  default     = ""
}

variable "budget_amount" {
  description = "Monthly budget. Alerts at 50%, 90% and 100%. It warns; it does not stop spending."
  type        = number
  default     = 5
}

variable "budget_currency" {
  description = "Must match the billing account's currency."
  type        = string
  default     = "EUR"
}
