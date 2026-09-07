# ---------------------------------------------------------------------------
# VNet peering — both halves.
#
# Peering is not a single object. It is two one-directional links, and a
# peering with only one half created shows as "Initiated" rather than
# "Connected" and passes no traffic. Creating both halves in the same module
# is what makes this atomic; splitting them across two root modules is a
# classic source of half-configured networks.
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-to-hub"
  resource_group_name       = azurerm_resource_group.spoke.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = var.hub_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true # traffic the firewall forwards back in

  # The spoke must not use the hub's gateway unless one exists. Setting this
  # true with no gateway deployed makes the peering fail to create.
  use_remote_gateways = false
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-to-${var.name_prefix}-spoke"
  resource_group_name       = var.hub_resource_group_name
  virtual_network_name      = var.hub_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
}
