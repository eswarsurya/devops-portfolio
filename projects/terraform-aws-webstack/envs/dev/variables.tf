variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "container_image" {
  type        = string
  description = "Image to run. Defaults to the API built by docker-cicd-pipeline (make the GHCR package public first)."
  default     = "ghcr.io/eswarsurya/devops-portfolio/docker-cicd-pipeline:latest"
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "health_check_path" {
  type    = string
  default = "/health"
}
