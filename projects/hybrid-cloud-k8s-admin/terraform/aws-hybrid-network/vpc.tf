# Three VPCs, two private subnets each (one per AZ). Only the shared VPC has public subnets and NAT:
# the others send internet traffic through the Transit Gateway to it (centralised egress).

locals {
  private_subnets = merge([
    for vpc, cidr in var.vpc_cidrs : {
      for i, az in var.azs : "${vpc}-${az}" => {
        vpc  = vpc
        az   = az
        cidr = cidrsubnet(cidr, 8, i)
      }
    }
  ]...)
}

resource "aws_vpc" "this" {
  for_each             = var.vpc_cidrs
  cidr_block           = each.value
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.environment}-${each.key}" }
}

resource "aws_subnet" "private" {
  for_each          = local.private_subnets
  vpc_id            = aws_vpc.this[each.value.vpc].id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags              = { Name = "${var.environment}-${each.key}-private", Tier = "private" }
}

resource "aws_route_table" "private" {
  for_each = var.vpc_cidrs
  vpc_id   = aws_vpc.this[each.key].id
  tags     = { Name = "${var.environment}-${each.key}-private" }
}

resource "aws_route_table_association" "private" {
  for_each       = local.private_subnets
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.value.vpc].id
}

# ---- public side of the shared VPC: internet gateway and NAT ----
resource "aws_subnet" "public" {
  for_each                = toset(var.azs)
  vpc_id                  = aws_vpc.this["shared"].id
  cidr_block              = cidrsubnet(var.vpc_cidrs["shared"], 8, 100 + index(var.azs, each.key))
  availability_zone       = each.key
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.environment}-shared-public-${each.key}", Tier = "public" }
}

resource "aws_internet_gateway" "shared" {
  vpc_id = aws_vpc.this["shared"].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this["shared"].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.shared.id
  }
  tags = { Name = "${var.environment}-shared-public" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

locals {
  nat_azs = var.single_nat_gateway ? [var.azs[0]] : var.azs
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"
}

resource "aws_nat_gateway" "shared" {
  for_each      = toset(local.nat_azs)
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = { Name = "${var.environment}-nat-${each.key}" }
}

resource "aws_route" "shared_default_via_nat" {
  route_table_id         = aws_route_table.private["shared"].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.shared[local.nat_azs[0]].id
}
