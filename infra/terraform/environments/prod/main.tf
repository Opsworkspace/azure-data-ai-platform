# ---------------------------------------------------------------------------
# PRODUCTION — dual-region, active-active.
#
# Read this file top to bottom to understand the whole platform. It is
# deliberately the only place where components are wired together; every
# module below is unaware of the others.
#
# Layer order, which is also the dependency order:
#
#   1. Naming            names and tags for everything
#   2. Shared groups     resource groups that outlive individual services
#   3. Observability     created FIRST, so every later resource can log to it
#   4. Network hub       firewall and bastion, per region
#   5. Network spoke     workload subnets, per region, peered to the hub
#   6. Private DNS       zones linked to every VNet
#   7. Data plane        Cosmos, lakehouse, Key Vault, registry
#   8. Compute           AKS, per region
#   9. Analytics & AI    Databricks and OpenAI, per region
#  10. Identity          workload identities federated to the clusters
#  11. Edge              Front Door in front of both regions
# ---------------------------------------------------------------------------

# ------------------------------------------------------------ 1. naming ----

module "naming_platform" {
  source   = "../../modules/naming"
  for_each = local.regions

  workload            = "plat"
  environment         = local.environment
  location            = each.value.location
  owner               = var.alert_email_receivers[0]
  cost_center         = var.cost_center
  data_classification = "confidential"
  uniqueness_seed     = var.subscription_id
  extra_tags          = local.common_tags
}

module "naming_data" {
  source   = "../../modules/naming"
  for_each = local.regions

  workload            = "data"
  environment         = local.environment
  location            = each.value.location
  owner               = var.alert_email_receivers[0]
  cost_center         = var.cost_center
  data_classification = "confidential"
  uniqueness_seed     = var.subscription_id
  extra_tags          = local.common_tags
}

module "naming_network" {
  source   = "../../modules/naming"
  for_each = local.regions

  workload            = "net"
  environment         = local.environment
  location            = each.value.location
  owner               = var.alert_email_receivers[0]
  cost_center         = var.cost_center
  data_classification = "internal"
  uniqueness_seed     = var.subscription_id
  extra_tags          = local.common_tags
}

# --------------------------------------------------- 2. shared groups ------

# Global resources live in the primary region's resource group. "Global" in
# Azure still means the control-plane record has to sit somewhere.
resource "azurerm_resource_group" "shared" {
  name     = "${module.naming_platform["primary"].base}-shared-rg"
  location = local.primary_location
  tags     = module.naming_platform["primary"].tags
}

resource "azurerm_resource_group" "data" {
  for_each = local.regions

  name     = "${module.naming_data[each.key].base}-rg"
  location = each.value.location
  tags     = module.naming_data[each.key].tags
}

# ----------------------------------------------------- 3. observability ----

# First, because every module after this takes a workspace id. A platform that
# adds observability last has a platform whose early failures are invisible.
module "observability" {
  source = "../../modules/observability"

  name_prefix         = module.naming_platform["primary"].base
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.primary_location
  tags                = module.naming_platform["primary"].tags

  # 90 days queryable. Long enough to investigate a quarterly pattern, short
  # enough to control cost. Anything older belongs in an archive tier.
  log_retention_days = 90

  # No daily cap in production. A cap protects the bill by dropping telemetry,
  # and the moment it matters most — a traffic spike or an incident — is
  # exactly when losing telemetry is most expensive. The bill is controlled by
  # sampling and table-level plans instead. Budget alerts catch overruns.
  daily_quota_gb = -1

  deploy_prometheus_and_grafana = true
  alert_email_receivers         = var.alert_email_receivers
  slo_target                    = local.slo_target
  enable_alerts                 = true
}

# -------------------------------------------------------- 4. network hub ---

module "hub" {
  source   = "../../modules/network-hub"
  for_each = local.regions

  resource_group_name = "${module.naming_network[each.key].base}-hub-rg"
  location            = each.value.location
  name_prefix         = module.naming_network[each.key].base
  tags                = module.naming_network[each.key].tags

  address_space = each.value.hub_cidr

  deploy_firewall   = true
  firewall_sku_tier = "Premium" # IDPS and TLS inspection
  deploy_bastion    = true
  bastion_sku       = "Standard"

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# Hub-to-hub peering. This is what makes the two regions one network: it
# carries cross-region replication traffic and lets an operator in one region
# reach the other through a single Bastion.
#
# Global VNet peering is charged per GB in BOTH directions. It is one of the
# quietly expensive line items in a multi-region design, and the reason data
# replication should use service-native replication (Cosmos, GZRS storage)
# rather than being pushed across the peering by application code.
resource "azurerm_virtual_network_peering" "hub_primary_to_secondary" {
  name                      = "peer-hub-primary-to-secondary"
  resource_group_name       = module.hub["primary"].resource_group_name
  virtual_network_name      = module.hub["primary"].vnet_name
  remote_virtual_network_id = module.hub["secondary"].vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "hub_secondary_to_primary" {
  name                      = "peer-hub-secondary-to-primary"
  resource_group_name       = module.hub["secondary"].resource_group_name
  virtual_network_name      = module.hub["secondary"].vnet_name
  remote_virtual_network_id = module.hub["primary"].vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
}

# ------------------------------------------------------ 5. network spoke ---

module "spoke" {
  source   = "../../modules/network-spoke"
  for_each = local.regions

  resource_group_name = "${module.naming_network[each.key].base}-spoke-rg"
  location            = each.value.location
  name_prefix         = module.naming_network[each.key].base
  tags                = module.naming_network[each.key].tags

  address_space = each.value.spoke_cidr

  hub_vnet_id             = module.hub[each.key].vnet_id
  hub_vnet_name           = module.hub[each.key].vnet_name
  hub_resource_group_name = module.hub[each.key].resource_group_name

  # Forced tunnelling: every packet leaving a workload subnet goes to the
  # regional firewall.
  firewall_private_ip = module.hub[each.key].firewall_private_ip

  enable_databricks_subnets  = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# -------------------------------------------------------- 6. private DNS ---

# One set of zones for the whole environment, linked to all four VNets. A
# workload in Central US resolving a private endpoint in East US 2 gets the
# right answer because the zone is linked to its VNet too.
module "private_dns" {
  source = "../../modules/private-dns"

  resource_group_name = "${module.naming_network["primary"].base}-dns-rg"
  location            = local.primary_location
  tags                = module.naming_network["primary"].tags

  vnet_links = merge(
    { for k, v in module.hub : "hub-${k}" => v.vnet_id },
    { for k, v in module.spoke : "spoke-${k}" => v.vnet_id },
  )

  enabled_zones = [
    "storage_blob",
    "storage_dfs",
    "key_vault",
    "container_registry",
    "cosmos_sql",
    "ai_search",
    "openai",
    "databricks",
    "monitor",
  ]
}
