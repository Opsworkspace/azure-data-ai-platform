# ---------------------------------------------------------------------------
# Hub VNet — the shared network core of one region.
#
# The hub holds no workloads. It holds the things that must be shared and must
# not be duplicated per application: the egress firewall, the jump path
# (Bastion), and the DNS resolution boundary. Spokes peer to it and route their
# internet-bound traffic through it.
#
# Why hub-and-spoke rather than one flat VNet:
#   * Blast radius. A misconfigured NSG in one spoke cannot reach another.
#   * Cost. One firewall per region, not one per application.
#   * Delegation. A spoke can be handed to a product team; the hub cannot.
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
  # Subnets are computed, never typed. Hand-allocating CIDRs is how overlaps
  # get into production; cidrsubnet() makes overlap arithmetically impossible.
  #
  # Given a /20 hub at 10.10.0.0/20 this yields:
  #   AzureFirewallSubnet            10.10.0.0/26    (name is mandated by Azure)
  #   AzureFirewallManagementSubnet  10.10.0.64/26   (mandated, forced tunnelling)
  #   AzureBastionSubnet             10.10.0.128/26  (mandated, minimum /26)
  #   GatewaySubnet                  10.10.0.192/26  (mandated, ExpressRoute/VPN)
  #   snet-shared                    10.10.1.0/24    (DNS resolver, jumpboxes)
  firewall_subnet_cidr            = cidrsubnet(var.address_space, 6, 0)
  firewall_management_subnet_cidr = cidrsubnet(var.address_space, 6, 1)
  bastion_subnet_cidr             = cidrsubnet(var.address_space, 6, 2)
  gateway_subnet_cidr             = cidrsubnet(var.address_space, 6, 3)
  shared_subnet_cidr              = cidrsubnet(var.address_space, 4, 1)

  diagnostics_enabled = var.log_analytics_workspace_id != ""
}

resource "azurerm_resource_group" "hub" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "${var.name_prefix}-hub-vnet"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  address_space       = [var.address_space]
  tags                = var.tags
}

# --- mandated subnets -------------------------------------------------------
# These four names are fixed by Azure. Using any other name makes the
# corresponding service refuse to deploy, which is a useful reminder that
# platform code is constrained by the platform, not only by preference.

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.firewall_subnet_cidr]
}

resource "azurerm_subnet" "firewall_management" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.firewall_management_subnet_cidr]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.bastion_subnet_cidr]
}

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.gateway_subnet_cidr]
}

resource "azurerm_subnet" "shared" {
  name                 = "snet-shared-services"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.shared_subnet_cidr]
}
