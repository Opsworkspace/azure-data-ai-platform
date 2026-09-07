# ------------------------------------------------------------ 7. data plane ---

# --- Key Vault, one per region ----------------------------------------------
# Regional rather than global. A global vault would be a cross-region
# dependency on the critical path of every pod start (the CSI driver mounts
# secrets at startup), which would mean an outage in the primary region takes
# down the secondary. The whole point of the second region is that it does not.
module "key_vault" {
  source   = "../../modules/key-vault"
  for_each = local.regions

  name                = module.naming_platform[each.key].key_vault_name
  resource_group_name = azurerm_resource_group.data[each.key].name
  location            = each.value.location
  tags                = module.naming_platform[each.key].tags
  tenant_id           = var.tenant_id

  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  sku_name                   = "standard"

  private_endpoint_subnet_id = module.spoke[each.key].private_endpoint_subnet_id
  private_dns_zone_ids       = [module.private_dns.zone_ids["privatelink.vaultcore.azure.net"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# --- container registry, one globally, replicated ---------------------------
# A single registry geo-replicated to both regions. Two independent registries
# would mean an image could exist in one region and not the other, which turns
# a failover into a deployment problem.
module "container_registry" {
  source = "../../modules/container-registry"

  name                = module.naming_platform["primary"].container_registry_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = local.primary_location
  tags                = module.naming_platform["primary"].tags

  sku                      = "Premium"
  georeplication_locations = [local.secondary_location]
  retention_days           = 30

  private_endpoint_subnet_id = module.spoke["primary"].private_endpoint_subnet_id
  private_dns_zone_ids       = [module.private_dns.zone_ids["privatelink.azurecr.io"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# The registry's private endpoint is in the primary spoke, but the secondary
# region's nodes must resolve and reach it too. They can, because the
# privatelink.azurecr.io zone is linked to every VNet and the hubs are peered.
# This is the payoff of centralising DNS: cross-region private endpoint access
# needs no extra configuration.

# --- Cosmos DB, one account spanning both regions ---------------------------
module "cosmosdb" {
  source = "../../modules/cosmosdb"

  name                = module.naming_data["primary"].cosmosdb_account_name
  resource_group_name = azurerm_resource_group.data["primary"].name
  location            = local.primary_location
  secondary_locations = [local.secondary_location]
  tags                = module.naming_data["primary"].tags

  # Session consistency plus multi-region writes. Both regions accept writes,
  # so a regional failure costs no write availability. The price is conflict
  # resolution (last-writer-wins on _ts by default) and roughly double the RU
  # charge per write.
  consistency_level          = "Session"
  enable_multi_region_writes = true
  zone_redundant             = true
  enable_serverless          = false
  backup_tier                = "Continuous30Days"

  database_name = "purple"

  containers = {
    # Partitioned by user. One million users means one million logical
    # partitions and near-perfect distribution. See modules/cosmosdb/main.tf
    # for why /tenantId would have been the wrong choice.
    users = {
      partition_key_path = "/userId"
      max_throughput     = 10000
      unique_key_paths   = ["/email"]
    }

    # Dataset metadata, also per user. The raw schema blob is excluded from
    # indexing: it is large, it is never queried by its contents, and indexing
    # it would be charged on every write.
    datasets = {
      partition_key_path   = "/userId"
      max_throughput       = 20000
      excluded_index_paths = ["/schemaDefinition/*", "/rawSample/*"]
    }

    # Conversation history for the AI assistant. TTL of 90 days: chat history
    # has declining value and unbounded growth, and an explicit TTL is far
    # cheaper than a scheduled deletion job.
    conversations = {
      partition_key_path   = "/userId"
      max_throughput       = 40000
      default_ttl_seconds  = 7776000
      excluded_index_paths = ["/messages/*"]
    }

    # Idempotency keys for the worker. Short TTL, high write rate, never
    # queried except by point read — so indexing is minimised.
    idempotency = {
      partition_key_path   = "/key"
      max_throughput       = 4000
      default_ttl_seconds  = 86400
      excluded_index_paths = ["/*"]
    }
  }

  private_endpoint_subnet_id = module.spoke["primary"].private_endpoint_subnet_id
  private_dns_zone_ids       = [module.private_dns.zone_ids["privatelink.documents.azure.com"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}

# --- lakehouse --------------------------------------------------------------
# One account, GZRS. Zone-redundant within the primary region AND
# asynchronously replicated to the paired region. Analytics is not on the
# API's critical path, so a lakehouse read failing during a regional outage
# degrades scheduled reporting rather than the product.
module "lakehouse" {
  source = "../../modules/lakehouse"

  name                = module.naming_data["primary"].storage_account_name
  resource_group_name = azurerm_resource_group.data["primary"].name
  location            = local.primary_location
  tags                = module.naming_data["primary"].tags

  replication_type            = "GZRS"
  delete_retention_days       = 30
  enable_lifecycle_management = true

  private_endpoint_subnet_id = module.spoke["primary"].private_endpoint_subnet_id
  blob_private_dns_zone_ids  = [module.private_dns.zone_ids["privatelink.blob.core.windows.net"]]
  dfs_private_dns_zone_ids   = [module.private_dns.zone_ids["privatelink.dfs.core.windows.net"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}
