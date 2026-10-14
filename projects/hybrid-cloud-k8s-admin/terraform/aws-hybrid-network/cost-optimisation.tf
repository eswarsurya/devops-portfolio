# Cost controls built into the network rather than added later.
#  1. S3 gateway endpoints: S3 traffic skips the NAT gateway (no per-GB NAT processing charge; the endpoint is free)
#  2. One shared NAT gateway for every VPC (see vpc.tf, var.single_nat_gateway)
#  3. App <-> data traffic uses peering, which has no Transit Gateway processing charge (see peering.tf)
#  4. A monthly budget with alerts, and Cost Anomaly Detection for sudden spikes
#  5. Lifecycle rules so logs move to cheaper storage and expire
#  6. Cost allocation tags on every resource (provider default_tags)

resource "aws_vpc_endpoint" "s3" {
  for_each          = var.vpc_cidrs
  vpc_id            = aws_vpc.this[each.key].id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private[each.key].id]
  tags              = { Name = "${var.environment}-${each.key}-s3" }
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Environment$%s", var.environment)]
  }

  dynamic "notification" {
    for_each = var.budget_alert_thresholds
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  # warn early if the month is on track to overspend
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }
}

resource "aws_ce_anomaly_monitor" "services" {
  name              = "${var.environment}-service-spend"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "daily" {
  name             = "${var.environment}-anomalies"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = var.budget_alert_emails[0]
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["25"]
    }
  }
}

# ---- log bucket with lifecycle tiers ----
resource "aws_s3_bucket" "logs" {
  bucket_prefix = "${var.environment}-network-logs-"
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 365
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# VPC flow logs for the hub VPC go straight to the cheap bucket, not CloudWatch Logs
resource "aws_flow_log" "shared" {
  vpc_id               = aws_vpc.this["shared"].id
  traffic_type         = "REJECT"
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.logs.arn
}
