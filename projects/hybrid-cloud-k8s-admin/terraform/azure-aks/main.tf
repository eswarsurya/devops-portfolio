# AKS cluster for the same workloads, in Azure: private API access via Entra ID, Azure CNI overlay,
# network policy, autoscaling user pool on spot-free nodes, and Container Insights.

locals {
  name = "hybrid-${var.environment}"
  tags = { Project = "hybrid-cloud", Environment = var.environment, ManagedBy = "terraform" }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.20.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.20.0.0/22"]
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_container_registry" "this" {
  name                = replace("acr${local.name}", "-", "")
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                      = "aks-${local.name}"
  location                  = azurerm_resource_group.this.location
  resource_group_name       = azurerm_resource_group.this.name
  dns_prefix                = local.name
  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.environment == "prod" ? "Standard" : "Free"
  automatic_upgrade_channel = "patch"
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  local_account_disabled    = true

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_size
    vnet_subnet_id               = azurerm_subnet.nodes.id
    node_count                   = 2
    only_critical_addons_enabled = true # system pods only; apps go to the user pool
    zones                        = ["1", "2", "3"]
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "10.21.0.0/16"
    dns_service_ip      = "10.21.0.10"
    load_balancer_sku   = "standard"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = "Sunday"
    start_time  = "02:00"
    duration    = 4
  }

  tags = local.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_size
  vnet_subnet_id        = azurerm_subnet.nodes.id
  mode                  = "User"
  auto_scaling_enabled  = true
  min_count             = var.user_pool_min
  max_count             = var.user_pool_max
  zones                 = ["1", "2", "3"]
  node_labels           = { workload = "apps" }
  upgrade_settings {
    max_surge = "33%"
  }
  tags = local.tags
}

# AKS pulls from ACR with its kubelet identity; no registry passwords
resource "azurerm_role_assignment" "aks_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
