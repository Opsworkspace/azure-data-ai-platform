# ---------------------------------------------------------------------------
# Route tables — forced tunnelling.
#
# By default an Azure subnet has a system route for 0.0.0.0/0 that points at
# the internet. That default is the thing being removed here: a user-defined
# route with nextHopType = VirtualAppliance overrides it and sends every
# packet with no more specific destination to the hub firewall.
#
# The subtlety that catches people: a private endpoint injects a /32 system
# route that is MORE specific than 0.0.0.0/0, so traffic to a private endpoint
# does NOT go via the firewall even with forced tunnelling on. That is correct
# and desirable — it stays on the Microsoft backbone — but it means the
# firewall logs will not show your Cosmos DB calls, and people waste hours
# looking for them.
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "spoke" {
  name                = "${var.name_prefix}-spoke-rt"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags

  # AKS creates and removes routes in the table attached to its subnets when
  # using kubenet. This platform uses Azure CNI Overlay, which does not, but
  # the guard costs nothing and prevents a class of plan churn.
  lifecycle {
    ignore_changes = [route]
  }
}

resource "azurerm_route" "default_via_firewall" {
  count = local.egress_via_firewall ? 1 : 0

  name                   = "default-to-firewall"
  resource_group_name    = azurerm_resource_group.spoke.name
  route_table_name       = azurerm_route_table.spoke.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.firewall_private_ip
}

# Attach to the node pool subnets and the integration subnet.
#
# NOT attached to: the private endpoint subnet (nothing egresses from it) and
# the Databricks subnets (Databricks manages its own routing for the secure
# cluster connectivity relay; a platform-imposed default route there breaks
# the control plane connection in a way that surfaces as clusters hanging in
# PENDING for 20 minutes before failing).

resource "azurerm_subnet_route_table_association" "aks_system" {
  subnet_id      = azurerm_subnet.aks_system.id
  route_table_id = azurerm_route_table.spoke.id
}

resource "azurerm_subnet_route_table_association" "aks_user" {
  subnet_id      = azurerm_subnet.aks_user.id
  route_table_id = azurerm_route_table.spoke.id
}

resource "azurerm_subnet_route_table_association" "aks_ai" {
  subnet_id      = azurerm_subnet.aks_ai.id
  route_table_id = azurerm_route_table.spoke.id
}

resource "azurerm_subnet_route_table_association" "integration" {
  subnet_id      = azurerm_subnet.integration.id
  route_table_id = azurerm_route_table.spoke.id
}
