# ------------------------------------------------------ 9. analytics and AI ---

module "databricks" {
  source   = "../../modules/databricks"
  for_each = local.regions

  name                        = module.naming_data[each.key].databricks_workspace_name
  resource_group_name         = azurerm_resource_group.data[each.key].name
  managed_resource_group_name = "${module.naming_data[each.key].base}-dbw-managed-rg"
  location                    = each.value.location
  tags                        = module.naming_data[each.key].tags

  sku = "premium" # Unity Catalog, cluster policies and audit logs are premium-only

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

  model_deployments = {
    # The chat model behind the assistant. Application code references the
    # DEPLOYMENT name "chat", so upgrading the model underneath is a Terraform
    # change with no code change and no redeploy.
    chat = {
      model_name    = "gpt-4o"
      model_version = "2024-11-20"
      # DataZoneStandard keeps inference inside the US data zone, which is
      # what the platform's stated US residency requirement demands.
      # GlobalStandard would give more throughput and break that promise.
      sku_name = "DataZoneStandard"
      capacity = 100 # 100k tokens/minute
    }

    # Embeddings for RAG. Far higher throughput than chat, because every
    # ingested document chunk is embedded once and every query is embedded
    # again — the embedding model sees vastly more calls than the chat model.
    embeddings = {
      model_name    = "text-embedding-3-large"
      model_version = "1"
      sku_name      = "Standard"
      capacity      = 350
    }
  }

  search_sku             = "standard"
  search_replica_count   = 3 # 3 replicas: required for the 99.9% read/write SLA
  search_partition_count = 2

  private_endpoint_subnet_id = module.spoke[each.key].private_endpoint_subnet_id
  openai_private_dns_zone_ids = [
    module.private_dns.zone_ids["privatelink.openai.azure.com"],
    module.private_dns.zone_ids["privatelink.cognitiveservices.azure.com"],
  ]
  search_private_dns_zone_ids = [module.private_dns.zone_ids["privatelink.search.windows.net"]]

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
}
