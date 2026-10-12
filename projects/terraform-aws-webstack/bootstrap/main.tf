# One-time setup: the S3 bucket that stores Terraform state for every env.
# Run this once with local state, then never touch it again.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique bucket name, e.g. eswar-tfstate-1234"
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # Protects against an accidental `terraform destroy` here.
  # Remove this line only when you are tearing everything down.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning = you can recover a previous state file if one gets corrupted
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}
