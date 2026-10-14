# Unit tests: plan against a mocked AWS provider (no account or credentials needed)
mock_provider "aws" {}

run "hub_and_spoke_routing" {
  command = plan

  assert {
    condition     = length(aws_vpc.this) == 3 && length(aws_subnet.private) == 6
    error_message = "expected three VPCs with two private subnets each"
  }
  assert {
    condition     = toset(keys(aws_ec2_transit_gateway_vpc_attachment.this)) == toset(["shared", "app"])
    error_message = "the shared and app VPCs must attach to the Transit Gateway; data must not"
  }
  assert {
    condition     = aws_ec2_transit_gateway.hub.default_route_table_association == "disable" && aws_ec2_transit_gateway.hub.default_route_table_propagation == "disable"
    error_message = "Transit Gateway routing must be explicit"
  }
  assert {
    condition     = aws_ec2_transit_gateway_route.default_to_shared.destination_cidr_block == "0.0.0.0/0"
    error_message = "internet traffic from spokes must go to the shared VPC (central egress)"
  }
  assert {
    condition     = aws_route.app_default_via_tgw.destination_cidr_block == "0.0.0.0/0"
    error_message = "the app VPC must send internet traffic to the hub"
  }
}

run "peering_between_app_and_data" {
  command = plan

  assert {
    condition     = aws_vpc_peering_connection.app_data.auto_accept == true
    error_message = "peering in the same account should be auto-accepted"
  }
  assert {
    condition     = aws_route.app_to_data.destination_cidr_block == var.vpc_cidrs["data"] && aws_route.data_to_app.destination_cidr_block == var.vpc_cidrs["app"]
    error_message = "both sides of the peering need a route to the other"
  }
}

run "site_to_site_vpn_to_onprem" {
  command = plan

  variables {
    onprem_cidr      = "172.30.10.0/24"
    onprem_public_ip = "198.51.100.7"
  }

  assert {
    condition     = aws_customer_gateway.onprem.ip_address == "198.51.100.7" && aws_customer_gateway.onprem.type == "ipsec.1"
    error_message = "customer gateway must point at the on-prem device"
  }
  assert {
    condition     = aws_vpn_connection.onprem.static_routes_only && aws_vpn_connection.onprem.tunnel1_ike_versions == toset(["ikev2"]) && aws_vpn_connection.onprem.tunnel2_ike_versions == toset(["ikev2"])
    error_message = "both tunnels must use IKEv2 with static routing"
  }
  assert {
    condition     = aws_ec2_transit_gateway_route.onprem.destination_cidr_block == "172.30.10.0/24"
    error_message = "the hub must route the on-prem network to the VPN"
  }
  assert {
    condition     = toset([for r in aws_route.to_onprem_via_tgw : r.destination_cidr_block]) == toset(["172.30.10.0/24"]) && length(aws_route.to_onprem_via_tgw) == 2
    error_message = "shared and app VPCs must route on-prem traffic to the hub"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.vpn_tunnel_down.metric_name == "TunnelState"
    error_message = "a tunnel-down alarm must exist"
  }
}
