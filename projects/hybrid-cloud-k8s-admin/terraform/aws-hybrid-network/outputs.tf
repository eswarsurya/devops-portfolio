output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.hub.id
}

output "vpc_ids" {
  value = { for k, v in aws_vpc.this : k => v.id }
}

output "vpn_tunnel_addresses" {
  description = "Configure these two endpoints on the on-prem VPN device"
  value       = [aws_vpn_connection.onprem.tunnel1_address, aws_vpn_connection.onprem.tunnel2_address]
}

output "nat_gateway_count" {
  value = length(aws_nat_gateway.shared)
}
