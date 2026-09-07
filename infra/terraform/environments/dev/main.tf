# ---------------------------------------------------------------------------
# DEVELOPMENT — single region, cost-optimised, same security posture.
#
# Compare this file with environments/prod/main.tf. The module calls are the
# same; only the arguments differ. That is the payoff of the module boundary:
# an environment is a set of decisions, not a fork of the code.
# ---------------------------------------------------------------------------

module "naming_platform" {
  source   = "../../modules/naming"
  for_each = local.regions

  workload            = "plat"
  environment         = local.environment
  location            = each.value.location
  owner               = var.alert_email_receivers[0]
  cost_center         = var.cost_center
  data_classification = "internal" # dev holds synthetic data only
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

  log_retention_days = 30 # the free floor

  # A hard cap here, unlike prod. In dev a runaway debug log is a cost bug,
  # not an incident, and dropping telemetry to stop it is the right trade.
  daily_quota_gb = 5

  # No Grafana instance for dev: it carries a fixed monthly cost, and dev
  # dashboards can be added to the production Grafana as a separate folder
  # pointing at this workspace.
  deploy_prometheus_and_grafana = false

  alert_email_receivers = var.alert_email_receivers
  slo_target            = local.slo_target
  enable_alerts         = false # nobody is paged for dev
}

module "hub" {
  source   = "../../modules/network-hub"
  for_each = local.regions

  resource_group_name = "${module.naming_network[each.key].base}-hub-rg"
  location            = each.value.location
  name_prefix         = module.naming_network[each.key].base
  tags                = module.naming_network[each.key].tags

  address_space = each.value.hub_cidr

  # The single largest cost saving available in dev, and the one with real
  # consequences. Without the firewall there is no egress allow-list, so a
  # workload that quietly depends on an unapproved FQDN works here and fails
  # in stage. Stage exists partly to catch exactly that.
  deploy_firewall = false

  # Bastion stays. It is the only way into a private network, and removing it
  # would push engineers toward the workaround this platform exists to
  # prevent: a VM with a public IP.
  deploy_bastion = true
  bastion_sku    = "Basic" # no native client, but ~40% cheaper

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

  # Null, because no firewall exists. The spoke module handles this by simply
  # not writing a default route, rather than writing a route to a null next
  # hop — which would black-hole all egress. Worth reading modules/
  # network-spoke/routes.tf to see how that degradation is expressed.
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

  # False in dev, and this is the reason the provider block above sets
  # purge_soft_delete_on_destroy. With purge protection ON, a destroyed dev
  # environment cannot be rebuilt under the same name for 7-90 days.
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

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

  # Premium anyway, despite the cost. Basic and Standard cannot have a private
  # endpoint, so dropping to them would mean dev's registry is the one
  # component reachable from the internet — breaking the property this
  # platform is built around, in the environment where people experiment most.
  sku                      = "Premium"
  georeplication_locations = []
  retention_days           = 7

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

  # Serverless: billed purely per request, no idle cost. A dev account that
  # nobody uses over a weekend costs approximately nothing, where a
  # provisioned 400 RU/s container costs the same whether used or not.
  #
  # What this hides: serverless has no autoscale behaviour to observe, a lower
  # per-container ceiling, and no multi-region behaviour at all. Any load
  # testing must happen in stage.
  enable_serverless          = true
  enable_multi_region_writes = false
  zone_redundant             = false
  consistency_level          = "Session"
  backup_tier                = "Continuous7Days"

  database_name = "purple"

  # Identical container definitions and partition keys to production. This is
  # NOT a place to economise: the partition key is the one thing that must be
  # validated against realistic data shapes before production, because it
  # cannot be changed afterwards.
  containers = {
    users         = { partition_key_path = "/userId", unique_key_paths = ["/email"] }
    datasets      = { partition_key_path = "/userId", excluded_index_paths = ["/schemaDefinition/*", "/rawSample/*"] }
    conversations = { partition_key_path = "/userId", default_ttl_seconds = 7776000, excluded_index_paths = ["/messages/*"] }
    idempotency   = { partition_key_path = "/key", default_ttl_seconds = 86400, excluded_index_paths = ["/*"] }
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

  replication_type      = "LRS" # dev data is synthetic and reproducible
  delete_retention_days = 7

  # Off in dev: lifecycle transitions incur early-deletion charges on data
  # that gets deleted within days anyway, so tiering costs more than it saves.
  enable_lifecycle_management = false

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

  # Free tier: no control-plane SLA, and a lower API server request ceiling.
  # Acceptable where an outage means an engineer waits, not a user.
  sku_tier = "Free"

  system_subnet_id = module.spoke[each.key].aks_system_subnet_id
  user_subnet_id   = module.spoke[each.key].aks_user_subnet_id
  ai_subnet_id     = module.spoke[each.key].aks_ai_subnet_id

  pod_cidr       = "10.244.0.0/16"
  service_cidr   = "172.16.0.0/16"
  dns_service_ip = "172.16.0.10"

  admin_group_object_ids = var.platform_admin_group_object_ids

  # Single zone, minimum viable counts. Two system nodes rather than one so
  # that a node drain during an upgrade does not take CoreDNS down entirely.
  system_node_pool = {
    vm_size   = "Standard_D2ds_v5"
    min_count = 2
    max_count = 3
    zones     = ["1"]
  }

  user_node_pool = {
    vm_size   = "Standard_D4ds_v5"
    min_count = 1
    max_count = 5
    zones     = ["1"]
    spot_pool = true # up to 90% off, and dev tolerates eviction
  }

  # No GPUs in dev. Inference against Azure OpenAI needs no local GPU, and a
  # single idle NC-series node would cost more than everything else here
  # combined.
  ai_node_pool = {
    enabled = false
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

  # Premium even in dev. Unity Catalog is premium-only, and developing
  # against a workspace without Unity Catalog means developing against a
  # different governance model than production uses.
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

  # Minimum viable capacity. Enough to develop against, nowhere near enough
  # to load test — which is a stage activity.
  model_deployments = {
    chat = {
      model_name    = "gpt-4o"
      model_version = "2024-11-20"
      sku_name      = "DataZoneStandard"
      capacity      = 10
    }
    embeddings = {
      model_name    = "text-embedding-3-large"
      model_version = "1"
      sku_name      = "Standard"
      capacity      = 30
    }
  }

  # Basic is the cheapest SKU that still supports a private endpoint.
  # One replica means no SLA, which is correct for dev.
  search_sku             = "basic"
  search_replica_count   = 1
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

  # Identical to production. The permission model is the thing least
  # acceptable to vary between environments: a workload that has more
  # permission in dev than prod will be written against dev's permissions and
  # fail in prod, and the failure will look like a bug rather than a policy.
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

# No Front Door in dev. The API is reached through the cluster's internal
# ingress from inside the VNet, or through Bastion. That means WAF rules and
# edge routing are NOT exercised here — a known gap, closed in stage.
