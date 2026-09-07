# ---------------------------------------------------------------------------
# Azure Bastion — the only interactive path into the private network.
#
# No virtual machine, node pool, or Databricks host in this platform has a
# public IP. That is not a preference; azure-policy/deny-public-ip.json makes
# it enforceable. The consequence is that operators need a sanctioned door,
# and this is it: a managed PaaS service that brokers RDP/SSH over TLS from
# the portal, with session logging, and no inbound rule on the target host.
#
# The alternative — a jumpbox VM with a public IP and an NSG allow-list of
# home IP addresses — is what most teams do first, and it is worse in every
# dimension: it is a patchable host, its allow-list rots, and it produces no
# session audit trail.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "bastion" {
  count = var.deploy_bastion ? 1 : 0

  name                = "${var.name_prefix}-bas-pip"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_bastion_host" "hub" {
  count = var.deploy_bastion ? 1 : 0

  name                = "${var.name_prefix}-bas"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = var.bastion_sku
  tags                = var.tags

  # Standard SKU only. Native client support lets an engineer run
  # `az network bastion ssh` from a terminal instead of a browser tab, which
  # is what makes the sanctioned path the convenient one. A security control
  # that is less convenient than the alternative gets bypassed.
  tunneling_enabled  = var.bastion_sku == "Standard"
  ip_connect_enabled = var.bastion_sku == "Standard"

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }

  depends_on = [azurerm_subnet_network_security_group_association.bastion]
}
