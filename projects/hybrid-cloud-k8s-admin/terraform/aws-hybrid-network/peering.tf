# App <-> data VPC peering: a direct, low-latency path for database traffic.
# Peering has no hourly or per-GB processing charge, unlike the Transit Gateway, so the
# busiest path (app to database) skips the hub. Peering is not transitive: data stays isolated
# from the shared VPC and on-prem.

resource "aws_vpc_peering_connection" "app_data" {
  vpc_id      = aws_vpc.this["app"].id
  peer_vpc_id = aws_vpc.this["data"].id
  auto_accept = true # same account and region

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = { Name = "${var.environment}-app-data" }
}

resource "aws_route" "app_to_data" {
  route_table_id            = aws_route_table.private["app"].id
  destination_cidr_block    = var.vpc_cidrs["data"]
  vpc_peering_connection_id = aws_vpc_peering_connection.app_data.id
}

resource "aws_route" "data_to_app" {
  route_table_id            = aws_route_table.private["data"].id
  destination_cidr_block    = var.vpc_cidrs["app"]
  vpc_peering_connection_id = aws_vpc_peering_connection.app_data.id
}
