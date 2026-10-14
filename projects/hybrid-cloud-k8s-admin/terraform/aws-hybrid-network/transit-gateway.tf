# Hub and spoke: the Transit Gateway connects the shared and app VPCs and the on-prem VPN.
# Default association/propagation are off so routing is explicit and reviewable.

resource "aws_ec2_transit_gateway" "hub" {
  description                     = "${var.environment} hub"
  amazon_side_asn                 = 64512
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"
  tags                            = { Name = "${var.environment}-hub" }
}

locals {
  tgw_attached_vpcs = toset(["shared", "app"])
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each           = local.tgw_attached_vpcs
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.this[each.key].id
  subnet_ids         = [for k, s in aws_subnet.private : s.id if local.private_subnets[k].vpc == each.key]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "${var.environment}-${each.key}" }
}

resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "${var.environment}-main" }
}

resource "aws_ec2_transit_gateway_route_table_association" "vpc" {
  for_each                       = aws_ec2_transit_gateway_vpc_attachment.this
  transit_gateway_attachment_id  = each.value.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "vpc" {
  for_each                       = aws_ec2_transit_gateway_vpc_attachment.this
  transit_gateway_attachment_id  = each.value.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# internet-bound traffic from any spoke goes to the shared VPC's NAT
resource "aws_ec2_transit_gateway_route" "default_to_shared" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this["shared"].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# ---- VPC route tables pointing at the hub ----
resource "aws_route" "app_default_via_tgw" {
  route_table_id         = aws_route_table.private["app"].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route" "to_onprem_via_tgw" {
  for_each               = local.tgw_attached_vpcs
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = var.onprem_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route" "shared_to_app_via_tgw" {
  route_table_id         = aws_route_table.private["shared"].id
  destination_cidr_block = var.vpc_cidrs["app"]
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# return path for NAT: replies to the app VPC leave the public subnets through the hub
resource "aws_route" "public_to_app_via_tgw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = var.vpc_cidrs["app"]
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}
