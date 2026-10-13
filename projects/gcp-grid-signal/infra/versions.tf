terraform {
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.20"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  # The budget API needs a quota project when called with user credentials (Cloud Shell).
  user_project_override = true
  billing_project       = var.project_id
}

data "google_project" "this" {}
