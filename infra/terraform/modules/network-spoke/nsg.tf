# ---------------------------------------------------------------------------
# Network security groups — the second layer of the defence in depth.
#
# The firewall controls what leaves the VNet. NSGs control what moves *inside*
# it. Both are needed: an attacker who lands on a node in the AI pool should
# not be able to reach the private endpoint subnet directly, and that is a
# lateral movement question the firewall never sees.
#
# Every NSG here follows the same shape:
#   1. Allow the specific flows the workload genuinely needs.
#   2. Allow Azure's mandatory infrastructure flows (load balancer probes).
#   3. Explicit terminal deny at 4096.
# ---------------------------------------------------------------------------

locals {
  # Written once, referenced by every NSG. Azure's health probes originate
  # from a service tag, not a routable address — blocking it silently kills
  # every load-balanced service in the subnet, and the symptom (endpoints
  # flapping to NotReady) points nowhere near the NSG.
  probe_rule = {
    name                       = "AllowAzureLoadBalancerProbes"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

# --- AKS node pools ---------------------------------------------------------

resource "azurerm_network_security_group" "aks" {
  for_each = toset(["system", "user", "ai"])

  name                = "${var.name_prefix}-aks-${each.key}-nsg"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags

  security_rule {
    name                       = "AllowIntraVnetInbound"
    description                = "Pod-to-pod and node-to-node traffic within the spoke."
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = local.probe_rule.name
    description                = "Mandatory. Blocking this silently breaks every Service of type LoadBalancer."
    priority                   = local.probe_rule.priority
    direction                  = local.probe_rule.direction
    access                     = local.probe_rule.access
    protocol                   = local.probe_rule.protocol
    source_port_range          = local.probe_rule.source_port_range
    destination_port_range     = local.probe_rule.destination_port_range
    source_address_prefix      = local.probe_rule.source_address_prefix
    destination_address_prefix = local.probe_rule.destination_address_prefix
  }

  security_rule {
    name                       = "DenyInternetInbound"
    description                = "Ingress arrives only via Front Door and the internal load balancer."
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    description                = "Explicit terminal deny, so drops are attributable in flow logs."
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks_system" {
  subnet_id                 = azurerm_subnet.aks_system.id
  network_security_group_id = azurerm_network_security_group.aks["system"].id
}

resource "azurerm_subnet_network_security_group_association" "aks_user" {
  subnet_id                 = azurerm_subnet.aks_user.id
  network_security_group_id = azurerm_network_security_group.aks["user"].id
}

resource "azurerm_subnet_network_security_group_association" "aks_ai" {
  subnet_id                 = azurerm_subnet.aks_ai.id
  network_security_group_id = azurerm_network_security_group.aks["ai"].id
}

# --- private endpoint subnet ------------------------------------------------
# Inbound only from inside the VNet. Nothing in this subnet ever needs to
# initiate a connection: a private endpoint NIC is a destination, never a
# source.

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "${var.name_prefix}-pe-nsg"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags

  security_rule {
    name                       = "AllowVnetToPrivateEndpoints"
    description                = "Workloads in this VNet, and peered VNets, reach PaaS over TLS."
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "1433", "5432", "6380", "10255"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "DenyAllInbound"
    description                = "Explicit terminal deny, so drops are attributable in flow logs."
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllOutbound"
    description                = "A private endpoint NIC is a destination, never a source."
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# --- Databricks -------------------------------------------------------------
# Deliberately minimal. Databricks injects its own required rules into these
# NSGs when the workspace is created; adding overlapping platform rules here
# causes workspace provisioning to fail with an error that does not mention
# the NSG. The platform contributes the terminal deny and nothing else.

resource "azurerm_network_security_group" "databricks" {
  count = var.enable_databricks_subnets ? 1 : 0

  name                = "${var.name_prefix}-dbx-nsg"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags

  lifecycle {
    # Databricks adds and removes rules in this NSG as part of managing the
    # workspace. Terraform must not fight it: without this, every plan after
    # workspace creation shows a diff that reverting would break the cluster.
    ignore_changes = [security_rule]
  }
}

resource "azurerm_subnet_network_security_group_association" "databricks_host" {
  count = var.enable_databricks_subnets ? 1 : 0

  subnet_id                 = azurerm_subnet.databricks_host[0].id
  network_security_group_id = azurerm_network_security_group.databricks[0].id
}

resource "azurerm_subnet_network_security_group_association" "databricks_container" {
  count = var.enable_databricks_subnets ? 1 : 0

  subnet_id                 = azurerm_subnet.databricks_container[0].id
  network_security_group_id = azurerm_network_security_group.databricks[0].id
}
