# AWS Site-to-Site VPN from the Transit Gateway to the on-prem data centre:
# two IPsec tunnels (AWS provides one per endpoint for redundancy), IKEv2, strong ciphers only.

resource "aws_customer_gateway" "onprem" {
  bgp_asn    = var.onprem_bgp_asn
  ip_address = var.onprem_public_ip
  type       = "ipsec.1"
  tags       = { Name = "${var.environment}-onprem-dc" }
}

resource "aws_vpn_connection" "onprem" {
  customer_gateway_id = aws_customer_gateway.onprem.id
  transit_gateway_id  = aws_ec2_transit_gateway.hub.id
  type                = "ipsec.1"
  static_routes_only  = true

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14]

  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_dh_group_numbers      = [14]

  tags = { Name = "${var.environment}-onprem-dc" }
}

resource "aws_ec2_transit_gateway_route_table_association" "vpn" {
  transit_gateway_attachment_id  = aws_vpn_connection.onprem.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# static route: on-prem network is reached through the VPN attachment
resource "aws_ec2_transit_gateway_route" "onprem" {
  destination_cidr_block         = var.onprem_cidr
  transit_gateway_attachment_id  = aws_vpn_connection.onprem.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# alarm if either tunnel goes down
resource "aws_cloudwatch_metric_alarm" "vpn_tunnel_down" {
  alarm_name          = "${var.environment}-onprem-vpn-tunnel-down"
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  dimensions          = { VpnId = aws_vpn_connection.onprem.id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  alarm_description   = "At least one Site-to-Site VPN tunnel to the on-prem DC is down"
  treat_missing_data  = "breaching"
}
