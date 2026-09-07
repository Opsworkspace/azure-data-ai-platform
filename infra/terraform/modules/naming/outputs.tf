output "tags" {
  description = "The standard tag set. Every resource in the platform must be tagged with at least this."
  value       = local.tags
}

output "region_abbreviation" {
  description = "Short code for the region, e.g. eus2."
  value       = local.region
}

output "environment_abbreviation" {
  description = "Short code for the environment, e.g. stg."
  value       = local.env
}

output "base" {
  description = "Hyphenated name stem, e.g. purple-plat-prod-eus2. Append a resource abbreviation to it."
  value       = local.base
}

output "unique_suffix" {
  description = "Deterministic six-character suffix used in globally-unique names."
  value       = local.unique
}

# ---------------------------------------------------------------------------
# Concrete names. Consumers reference these rather than reassembling strings,
# so a change to the convention is a one-file change.
# ---------------------------------------------------------------------------

output "resource_group_name" {
  description = "Resource group name."
  value       = "${local.base}-rg"
}

output "virtual_network_name" {
  description = "Virtual network name."
  value       = "${local.base}-vnet"
}

output "route_table_name" {
  description = "Route table name."
  value       = "${local.base}-rt"
}

output "firewall_name" {
  description = "Azure Firewall name."
  value       = "${local.base}-afw"
}

output "bastion_name" {
  description = "Azure Bastion host name."
  value       = "${local.base}-bas"
}

output "aks_cluster_name" {
  description = "AKS managed cluster name."
  value       = "${local.base}-aks"
}

output "aks_node_resource_group_name" {
  description = "The MC_ resource group AKS creates for its own nodes. Named explicitly so it is not the unreadable Azure default."
  value       = "${local.base}-aks-nodes-rg"
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  value       = "${local.base}-log"
}

output "application_insights_name" {
  description = "Application Insights component name."
  value       = "${local.base}-appi"
}

output "monitor_workspace_name" {
  description = "Azure Monitor workspace (managed Prometheus) name."
  value       = "${local.base}-amw"
}

output "grafana_name" {
  description = "Azure Managed Grafana name."
  value       = "${local.base}-graf"
}

output "databricks_workspace_name" {
  description = "Azure Databricks workspace name."
  value       = "${local.base}-dbw"
}

output "front_door_name" {
  description = "Azure Front Door profile name."
  value       = "${local.base}-afd"
}

output "user_assigned_identity_name" {
  description = "User-assigned managed identity name stem. Append a purpose, e.g. -api."
  value       = "${local.base}-id"
}

output "openai_account_name" {
  description = "Azure OpenAI (Cognitive Services) account name."
  value       = "${local.base}-oai"
}

output "search_service_name" {
  description = "Azure AI Search service name."
  value       = "${local.base}-srch"
}

# --- globally-unique namespaces --------------------------------------------

output "storage_account_name" {
  description = "Storage account name: 24 chars, lowercase alphanumeric, globally unique."
  value       = local.storage_account_name
}

output "key_vault_name" {
  description = "Key Vault name: 24 chars, globally unique."
  value       = local.key_vault_name
}

output "container_registry_name" {
  description = "Container registry name: alphanumeric, globally unique."
  value       = local.container_registry_name
}

output "cosmosdb_account_name" {
  description = "Cosmos DB account name: globally unique."
  value       = local.cosmosdb_account_name
}
