output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}
