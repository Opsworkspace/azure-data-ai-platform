# ---------------------------------------------------------------------------
# STAGING — single region, production fidelity.
#
# Same module calls as dev and prod. The arguments sit between the two: full
# production behaviour on everything that can be validated in one region, and
# reduced scale everywhere that only costs money.
# ---------------------------------------------------------------------------

module "naming_platform" {
  source   = "../../modules/naming"
  for_each = local.regions

  workload            = "plat"
  environment         = local.environment
  location            = each.value.location
  owner               = var.alert_email_receivers[0]
  cost_center         = var.cost_center
  data_classification = "confidential" # stage may hold copies of real shapes
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
  data_classification = "internal"
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

module "observability" {
  source = "../../modules/observability"

  name_prefix         = module.naming_platform["primary"].base
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.primary_location
  tags                = module.naming_platform["primary"].tags

  log_retention_days = 30
  daily_quota_gb     = 20

  # Grafana and managed Prometheus are deployed here, because the dashboards
  # themselves are an artefact that has to be validated before production
  # depends on them.
  deploy_prometheus_and_grafana = true

  alert_email_receivers = var.alert_email_receivers
  slo_target            = local.slo_target

  # Alerts ON, at production thresholds. Stage is where a burn-rate alert that
  # fires constantly, or never fires at all, gets discovered.
  enable_alerts = true
}

module "hub" {
  source   = "../../modules/network-hub"
  for_each = local.regions

  resource_group_name = "${module.naming_network[each.key].base}-hub-rg"
  location            = each.value.location
  name_prefix         = module.naming_network[each.key].base
  tags                = module.naming_network[each.key].tags

  address_space = each.value.hub_cidr

  # The firewall is the whole reason stage exists. Standard rather than
  # Premium: the egress ALLOW-LIST behaviour is identical, and IDPS/TLS
  # inspection are the parts that do not need pre-production validation.
  deploy_firewall   = true
  firewall_sku_tier = "Standard"

  deploy_bastion = true
  bastion_sku    = "Standard"

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

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

  # Forced tunnelling, exactly as in production.
  firewall_private_ip = module.hub[each.key].firewall_private_ip

  enable_databricks_subnets  = true
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

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
    "storage_blob", "storage_dfs", "key_vault", "container_registry",
    "cosmos_sql", "ai_search", "openai", "databricks", "monitor",
  ]
}

module "key_vault" {
  source   = "../../modules/key-vault"
  for_each = local.regions

  name                = module.naming_platform[each.key].key_vault_name
  resource_group_name = azurerm_resource_group.data[each.key].name
  location            = each.value.location
  tags                = module.naming_platform[each.key].tags
  tenant_id           = var.tenant_id

  # On, as in production. Stage is not torn down nightly, so the name
  # reservation that makes this painful in dev is not a problem here.
  purge_protection_enabled   = true
  soft_delete_retention_days = 30

  private_endpoint_subnet_id = module.spoke[each.key].private_endpoint_subnet_id
  private_dns_zone_ids       = [module.private_dns.zone_ids["privatelink.vaultcore.azure.net"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

module "container_registry" {
  source = "../../modules/container-registry"

  name                = module.naming_platform["primary"].container_registry_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.primary_location
  tags                = module.naming_platform["primary"].tags

  sku                      = "Premium"
  georeplication_locations = [] # single region, so nothing to replicate to
  retention_days           = 30

  private_endpoint_subnet_id = module.spoke["primary"].private_endpoint_subnet_id
  private_dns_zone_ids       = [module.private_dns.zone_ids["privatelink.azurecr.io"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

module "cosmosdb" {
  source = "../../modules/cosmosdb"

  name                = module.naming_data["primary"].cosmosdb_account_name
  resource_group_name = azurerm_resource_group.data["primary"].name
  location            = local.primary_location
  secondary_locations = []
  tags                = module.naming_data["primary"].tags

  # Provisioned with autoscale, single region. This is the configuration
  # under which RU-per-operation, autoscale response time and 429 handling can
  # actually be measured — none of which serverless exposes.
  enable_serverless          = false
  enable_multi_region_writes = false # single region: nothing to write to
  zone_redundant             = true
  consistency_level          = "Session"
  backup_tier                = "Continuous7Days"

  database_name = "purple"

  # Same partition keys as production, at one-tenth the throughput. The
  # throughput is what scales down; the partition key never varies between
  # environments, because it is the thing being validated.
  containers = {
    users         = { partition_key_path = "/userId", max_throughput = 1000, unique_key_paths = ["/email"] }
    datasets      = { partition_key_path = "/userId", max_throughput = 2000, excluded_index_paths = ["/schemaDefinition/*", "/rawSample/*"] }
    conversations = { partition_key_path = "/userId", max_throughput = 4000, default_ttl_seconds = 7776000, excluded_index_paths = ["/messages/*"] }
    idempotency   = { partition_key_path = "/key", max_throughput = 1000, default_ttl_seconds = 86400, excluded_index_paths = ["/*"] }
  }

  private_endpoint_subnet_id = module.spoke["primary"].private_endpoint_subnet_id
  private_dns_zone_ids       = [module.private_dns.zone_ids["privatelink.documents.azure.com"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

module "lakehouse" {
  source = "../../modules/lakehouse"

  name                = module.naming_data["primary"].storage_account_name
  resource_group_name = azurerm_resource_group.data["primary"].name
  location            = local.primary_location
  tags                = module.naming_data["primary"].tags

  # ZRS rather than GZRS: zone redundancy is validated, geo-replication is a
  # billing line with nothing to prove in a single-region environment.
  replication_type      = "ZRS"
  delete_retention_days = 14

  # On, so the lifecycle rules themselves are exercised against real blobs
  # before they are trusted with production data.
  enable_lifecycle_management = true

  private_endpoint_subnet_id = module.spoke["primary"].private_endpoint_subnet_id
  blob_private_dns_zone_ids  = [module.private_dns.zone_ids["privatelink.blob.core.windows.net"]]
  dfs_private_dns_zone_ids   = [module.private_dns.zone_ids["privatelink.dfs.core.windows.net"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

module "aks" {
  source   = "../../modules/aks"
  for_each = local.regions

  name                     = module.naming_platform[each.key].aks_cluster_name
  node_resource_group_name = module.naming_platform[each.key].aks_node_resource_group_name
  resource_group_name      = azurerm_resource_group.data[each.key].name
  location                 = each.value.location
  tags                     = module.naming_platform[each.key].tags

  kubernetes_version = "1.31"

  # Standard, matching production. Load tests against a Free-tier control
  # plane measure the wrong thing.
  sku_tier = "Standard"

  system_subnet_id = module.spoke[each.key].aks_system_subnet_id
  user_subnet_id   = module.spoke[each.key].aks_user_subnet_id
  ai_subnet_id     = module.spoke[each.key].aks_ai_subnet_id

  pod_cidr       = "10.244.0.0/16"
  service_cidr   = "172.16.0.0/16"
  dns_service_ip = "172.16.0.10"

  admin_group_object_ids = var.platform_admin_group_object_ids

  # Three zones, as in production, so zone-failure behaviour is real. Smaller
  # VM SKUs and lower ceilings: the SHAPE matches production, the SCALE does
  # not.
  system_node_pool = {
    vm_size   = "Standard_D2ds_v5"
    min_count = 3
    max_count = 4
    zones     = ["1", "2", "3"]
  }

  user_node_pool = {
    vm_size   = "Standard_D4ds_v5"
    min_count = 3
    max_count = 10
    zones     = ["1", "2", "3"]
    spot_pool = true
  }

  ai_node_pool = {
    enabled = false # inference goes to Azure OpenAI; no local GPU needed
  }

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  prometheus_workspace_id    = module.observability.prometheus_workspace_id
  container_registry_id      = module.container_registry.id
}

module "databricks" {
  source   = "../../modules/databricks"
  for_each = local.regions

  name                        = module.naming_data[each.key].databricks_workspace_name
  resource_group_name         = azurerm_resource_group.data[each.key].name
  managed_resource_group_name = "${module.naming_data[each.key].base}-dbw-managed-rg"
  location                    = each.value.location
  tags                        = module.naming_data[each.key].tags

  sku = "premium"

  virtual_network_id    = module.spoke[each.key].vnet_id
  host_subnet_name      = module.spoke[each.key].databricks_host_subnet_name
  container_subnet_name = module.spoke[each.key].databricks_container_subnet_name

  host_subnet_nsg_association_id      = module.spoke[each.key].databricks_host_nsg_association_id
  container_subnet_nsg_association_id = module.spoke[each.key].databricks_container_nsg_association_id

  lakehouse_storage_account_id = module.lakehouse.id
  log_analytics_workspace_id   = module.observability.log_analytics_workspace_id
}

module "ai_services" {
  source   = "../../modules/ai-services"
  for_each = local.regions

  openai_name         = module.naming_data[each.key].openai_account_name
  search_name         = module.naming_data[each.key].search_service_name
  resource_group_name = azurerm_resource_group.data[each.key].name
  location            = each.value.location
  tags                = module.naming_data[each.key].tags

  # Enough capacity to load test the RAG path end to end, which is the
  # activity dev cannot support.
  model_deployments = {
    chat = {
      model_name    = "gpt-4o"
      model_version = "2024-11-20"
      sku_name      = "DataZoneStandard"
      capacity      = 30
    }
    embeddings = {
      model_name    = "text-embedding-3-large"
      model_version = "1"
      sku_name      = "Standard"
      capacity      = 100
    }
  }

  # Two replicas: the minimum for a read SLA, so query behaviour under
  # replica failover is observable.
  search_sku             = "standard"
  search_replica_count   = 2
  search_partition_count = 1

  private_endpoint_subnet_id = module.spoke[each.key].private_endpoint_subnet_id
  openai_private_dns_zone_ids = [
    module.private_dns.zone_ids["privatelink.openai.azure.com"],
    module.private_dns.zone_ids["privatelink.cognitiveservices.azure.com"],
  ]
  search_private_dns_zone_ids = [module.private_dns.zone_ids["privatelink.search.windows.net"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

module "workload_identity" {
  source   = "../../modules/identity"
  for_each = local.regions

  resource_group_name = azurerm_resource_group.data[each.key].name
  location            = each.value.location
  name_prefix         = module.naming_platform[each.key].base
  tags                = module.naming_platform[each.key].tags

  oidc_issuer_url = module.aks[each.key].oidc_issuer_url

  # Identical to production and to dev. The permission model never varies
  # between environments.
  workload_identities = {
    api = {
      kubernetes_namespace       = "purple"
      kubernetes_service_account = "purple-api"
      role_assignments = [
        { role_definition_name = "Cosmos DB Built-in Data Contributor", scope = module.cosmosdb.id },
        { role_definition_name = "Key Vault Secrets User", scope = module.key_vault[each.key].id },
        { role_definition_name = "Cognitive Services OpenAI User", scope = module.ai_services[each.key].openai_id },
        { role_definition_name = "Search Index Data Reader", scope = module.ai_services[each.key].search_id },
      ]
    }
    worker = {
      kubernetes_namespace       = "purple"
      kubernetes_service_account = "purple-worker"
      role_assignments = [
        { role_definition_name = "Cosmos DB Built-in Data Contributor", scope = module.cosmosdb.id },
        { role_definition_name = "Storage Blob Data Contributor", scope = module.lakehouse.id },
        { role_definition_name = "Search Index Data Contributor", scope = module.ai_services[each.key].search_id },
        { role_definition_name = "Cognitive Services OpenAI User", scope = module.ai_services[each.key].openai_id },
        { role_definition_name = "Key Vault Secrets User", scope = module.key_vault[each.key].id },
      ]
    }
  }

  github_federated_identities = {}
}

resource "azurerm_role_assignment" "csi_key_vault_secrets_user" {
  for_each = local.regions

  scope                = module.key_vault[each.key].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.aks[each.key].key_vault_secrets_provider_identity_object_id
  principal_type       = "ServicePrincipal"
}

# --- edge -------------------------------------------------------------------
# Front Door and the WAF, with ONE origin. Everything about the edge except
# cross-region failover is validated here: TLS termination, routing, rate
# limits, and above all the WAF's false-positive rate against real traffic.
#
# waf_mode is Detection, not Prevention. This is the whole point of a staging
# WAF: run it in Detection, drive realistic traffic through it, read
# FrontDoorWebApplicationFirewallLog, and add exclusions for the managed rules
# that matched legitimate requests. Promoting to Prevention in production
# without that data is how a deployment blocks real users on day one.
module "front_door" {
  source = "../../modules/front-door"

  name                = module.naming_platform["primary"].front_door_name
  resource_group_name = azurerm_resource_group.shared.name
  tags                = module.naming_platform["primary"].tags

  sku_name = "Premium_AzureFrontDoor"

  origins = {
    eastus2 = {
      host_name = "ingress-stage-eastus2.purple.example.com"
      priority  = 1
      weight    = 500
    }
  }

  custom_domain = "api-stage.purple.example.com"

  waf_mode             = "Detection"
  rate_limit_threshold = 1000
  health_probe_path    = "/healthz/ready"

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}
