# Unit tests: plan against a mocked azurerm provider (no subscription needed)
mock_provider "azurerm" {}

# AKS creates the kubelet identity itself; give the mock one so the AcrPull assignment can reference it
override_resource {
  target          = azurerm_kubernetes_cluster.this
  override_during = plan
  values = {
    kubelet_identity = [{
      client_id                 = "00000000-0000-0000-0000-00000000000a"
      object_id                 = "00000000-0000-0000-0000-00000000000b"
      user_assigned_identity_id = "/subscriptions/0/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/kubelet"
    }]
  }
}

run "secure_cluster_defaults" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled && azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
    error_message = "access must go through Entra ID and Azure RBAC, with no local admin account"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].network_policy == "azure" && azurerm_kubernetes_cluster.this.network_profile[0].network_plugin_mode == "overlay"
    error_message = "expected Azure CNI overlay with network policy enforcement"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].only_critical_addons_enabled
    error_message = "the system pool should run system pods only"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.workload_identity_enabled && azurerm_kubernetes_cluster.this.oidc_issuer_enabled
    error_message = "workload identity is needed so pods use Entra ID instead of secrets"
  }
  assert {
    condition     = azurerm_container_registry.this.admin_enabled == false && azurerm_role_assignment.aks_pull.role_definition_name == "AcrPull"
    error_message = "AKS must pull from ACR with its identity, not registry passwords"
  }
}

run "user_pool_autoscales" {
  command = plan

  variables {
    user_pool_min = 2
    user_pool_max = 8
  }

  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.user.auto_scaling_enabled && azurerm_kubernetes_cluster_node_pool.user.min_count == 2 && azurerm_kubernetes_cluster_node_pool.user.max_count == 8
    error_message = "the user pool must autoscale within the given bounds"
  }
}

run "prod_gets_the_paid_sla_tier" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.sku_tier == "Standard"
    error_message = "production should use the Standard (SLA-backed) tier"
  }
}
