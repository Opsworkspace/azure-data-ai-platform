# ---------------------------------------------------------------------------
# Spoke VNet — where workloads actually run.
#
# One spoke per environment per region. It peers to the region's hub, sends
# all internet-bound traffic through the hub firewall, and terminates every
# PaaS dependency on a private endpoint inside its own subnet.
#
# Subnet layout is computed from a single /16 so that adding a region is a
# one-line change and CIDR overlap is arithmetically impossible.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

locals {
  # Given a /16 at 10.11.0.0/16 this yields:
  #   snet-aks-system        10.11.0.0/22   1019 usable — system node pool
  #   snet-aks-user          10.11.4.0/22   1019 usable — application node pool
  #   snet-aks-ai            10.11.8.0/22   1019 usable — GPU / inference pool
  #   snet-private-endpoints 10.11.12.0/24   251 usable — one NIC per PaaS service
  #   snet-databricks-host   10.11.16.0/22  Databricks driver/worker NICs
  #   snet-databricks-cntr   10.11.20.0/22  Databricks container NICs (paired)
  #   snet-integration       10.11.24.0/24  future: App Service / Container Apps
  #
  # Azure reserves 5 addresses in every subnet (network, gateway, two DNS,
  # broadcast), which is why a /22 gives 1019 and not 1024. That reservation
  # is a real capacity-planning input, not trivia.
  subnets = {
    aks_system        = cidrsubnet(var.address_space, 6, 0)
    aks_user          = cidrsubnet(var.address_space, 6, 1)
    aks_ai            = cidrsubnet(var.address_space, 6, 2)
    private_endpoints = cidrsubnet(var.address_space, 8, 12)
    databricks_host   = cidrsubnet(var.address_space, 6, 4)
    databricks_cntr   = cidrsubnet(var.address_space, 6, 5)
    integration       = cidrsubnet(var.address_space, 8, 24)
  }

  diagnostics_enabled = var.log_analytics_workspace_id != ""

  # A null firewall IP means "no egress appliance in this environment".
  # The route tables below degrade to Azure's default routing rather than
  # black-holing traffic, which is what a naive `0.0.0.0/0 -> null` would do.
  egress_via_firewall = var.firewall_private_ip != null
}

resource "azurerm_resource_group" "spoke" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "spoke" {
  name                = "${var.name_prefix}-spoke-vnet"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = azurerm_resource_group.spoke.location
  address_space       = [var.address_space]
  tags                = var.tags
}

# --- AKS node subnets -------------------------------------------------------
# Three pools, three subnets. Separating them by subnet rather than only by
# node taint means an NSG can express "the AI pool may not reach the internet"
# — a policy that cannot be written against a taint.

resource "azurerm_subnet" "aks_system" {
  name                 = "snet-aks-system"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.subnets.aks_system]
}

resource "azurerm_subnet" "aks_user" {
  name                 = "snet-aks-user"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.subnets.aks_user]
}

resource "azurerm_subnet" "aks_ai" {
  name                 = "snet-aks-ai"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.subnets.aks_ai]
}

# --- private endpoint subnet ------------------------------------------------
# Every PaaS service the platform uses lands a NIC here. One subnet for all of
# them, because private endpoints do not talk to each other and separating
# them buys nothing but address-space fragmentation.

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.subnets.private_endpoints]

  # Network policies must be disabled for the subnet to host private
  # endpoints at all. In azurerm 4.x this is a single tri-state field; older
  # guides referring to two booleans are out of date.
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "integration" {
  name                 = "snet-integration"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.subnets.integration]
}

# --- Databricks subnet pair -------------------------------------------------
# VNet injection ("secure cluster connectivity") requires exactly two subnets,
# both delegated to Microsoft.Databricks/workspaces, both with an NSG, and
# neither shared with anything else. Databricks writes its own NSG rules into
# those NSGs at workspace creation — which is why the NSGs below carry only
# the platform's own rules and leave room for the service's.

resource "azurerm_subnet" "databricks_host" {
  count = var.enable_databricks_subnets ? 1 : 0

  name                 = "snet-databricks-host"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.subnets.databricks_host]

  delegation {
    name = "databricks-host"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet" "databricks_container" {
  count = var.enable_databricks_subnets ? 1 : 0

  name                 = "snet-databricks-container"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.subnets.databricks_cntr]

  delegation {
    name = "databricks-container"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}
