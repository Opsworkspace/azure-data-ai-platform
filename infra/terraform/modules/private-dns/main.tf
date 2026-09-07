# ---------------------------------------------------------------------------
# Private DNS zones for private endpoints.
#
# This module is the one people skip, and it is the one that breaks everything.
#
# A private endpoint gives a PaaS service a private IP inside your VNet. It
# does NOT change what the service's hostname resolves to. Without a private
# DNS zone, a client inside the VNet resolving
# `purpleprodeus2.blob.core.windows.net` still gets the service's PUBLIC IP,
# sends the packet out through the firewall, and gets denied — because
# `public_network_access_enabled = false` is set on the service.
#
# The failure looks like a firewall problem. It is a DNS problem.
#
# How the resolution actually works:
#   1. Client asks for purpleprodeus2.blob.core.windows.net
#   2. Azure DNS returns a CNAME to purpleprodeus2.privatelink.blob.core.windows.net
#   3. The linked private zone answers that name with the private endpoint IP
#   4. Traffic stays on the VNet
#
# Step 3 only happens if the zone is linked to the VNet the client sits in.
# That is what var.vnet_links controls, and why every spoke must be listed.
#
# Zone ownership: these zones are created once, in a shared resource group,
# and linked to many VNets. Two zones with the same name in one tenant is
# legal but produces non-deterministic resolution depending on link order.
# One zone, many links, is the only safe topology.
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
  # The authoritative mapping from a service to its privatelink zone name.
  # These strings are defined by Microsoft and cannot be chosen; getting one
  # character wrong produces a zone that resolves nothing, silently.
  #
  # Several services need more than one zone. Storage is the sharpest example:
  # a single ADLS Gen2 account serves blob and dfs endpoints on different
  # hostnames, so a lakehouse that only links `blob` will have Spark fail on
  # `abfss://` paths while `wasbs://` paths work.
  all_zones = {
    storage_blob       = ["privatelink.blob.core.windows.net"]
    storage_dfs        = ["privatelink.dfs.core.windows.net"]
    storage_queue      = ["privatelink.queue.core.windows.net"]
    storage_table      = ["privatelink.table.core.windows.net"]
    storage_file       = ["privatelink.file.core.windows.net"]
    key_vault          = ["privatelink.vaultcore.azure.net"]
    container_registry = ["privatelink.azurecr.io"]
    cosmos_sql         = ["privatelink.documents.azure.com"]
    cosmos_mongo       = ["privatelink.mongo.cosmos.azure.com"]
    ai_search          = ["privatelink.search.windows.net"]
    openai             = ["privatelink.openai.azure.com", "privatelink.cognitiveservices.azure.com"]
    databricks         = ["privatelink.azuredatabricks.net"]
    service_bus        = ["privatelink.servicebus.windows.net"]

    # Azure Monitor Private Link Scope needs five zones together. Linking
    # four of five means agents intermittently fail to upload, which presents
    # as gaps in dashboards rather than as an error.
    monitor = [
      "privatelink.monitor.azure.com",
      "privatelink.oms.opinsights.azure.com",
      "privatelink.ods.opinsights.azure.com",
      "privatelink.agentsvc.azure-automation.net",
      "privatelink.blob.core.windows.net",
    ]
  }

  # Flatten the selected groups into a deduplicated set of zone names.
  # Deduplication matters: monitor and storage_blob both want
  # privatelink.blob.core.windows.net, and creating it twice is an error.
  selected_zone_names = toset(flatten([
    for group in var.enabled_zones : local.all_zones[group]
  ]))

  # Cartesian product of zones and VNets, keyed so that adding a VNet does not
  # force replacement of existing links.
  zone_vnet_links = {
    for pair in setproduct(local.selected_zone_names, keys(var.vnet_links)) :
    "${pair[0]}|${pair[1]}" => {
      zone_name = pair[0]
      link_name = pair[1]
      vnet_id   = var.vnet_links[pair[1]]
    }
  }
}

resource "azurerm_resource_group" "dns" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_private_dns_zone" "zones" {
  for_each = local.selected_zone_names

  name                = each.value
  resource_group_name = azurerm_resource_group.dns.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each = local.zone_vnet_links

  name                  = "link-${each.value.link_name}"
  resource_group_name   = azurerm_resource_group.dns.name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.value.zone_name].name
  virtual_network_id    = each.value.vnet_id
  tags                  = var.tags

  # Auto-registration is for VMs registering their own A records. Private
  # endpoint zones must NOT have it: the endpoint's A record is written by the
  # private-dns-zone-group on the endpoint itself, and auto-registration in
  # the same zone causes conflicting records.
  registration_enabled = false
}
