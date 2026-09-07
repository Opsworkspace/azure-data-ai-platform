# --------------------------------------------------------------- 8. compute ---

module "aks" {
  source   = "../../modules/aks"
  for_each = local.regions

  name                     = module.naming_platform[each.key].aks_cluster_name
  node_resource_group_name = module.naming_platform[each.key].aks_node_resource_group_name
  resource_group_name      = azurerm_resource_group.data[each.key].name
  location                 = each.value.location
  tags                     = module.naming_platform[each.key].tags

  kubernetes_version = "1.31"
  sku_tier           = "Standard" # 99.95% control-plane SLA

  system_subnet_id = module.spoke[each.key].aks_system_subnet_id
  user_subnet_id   = module.spoke[each.key].aks_user_subnet_id
  ai_subnet_id     = module.spoke[each.key].aks_ai_subnet_id

  # Overlay pod CIDR. Identical in both regions ON PURPOSE: overlay addresses
  # are not routable outside the cluster, so they cannot collide. Reusing the
  # same range keeps NetworkPolicy manifests identical across regions.
  pod_cidr       = "10.244.0.0/16"
  service_cidr   = "172.16.0.0/16"
  dns_service_ip = "172.16.0.10"

  admin_group_object_ids = var.platform_admin_group_object_ids

  system_node_pool = {
    vm_size   = "Standard_D4ds_v5"
    min_count = 3 # one per availability zone
    max_count = 6
  }

  user_node_pool = {
    vm_size   = "Standard_D8ds_v5"
    min_count = 3
    max_count = 30
    spot_pool = true # for the queue worker, which is interruption-tolerant
  }

  ai_node_pool = {
    enabled   = true
    vm_size   = "Standard_NC4as_T4_v3"
    min_count = 0 # scale to zero when no inference is running
    max_count = 4
  }

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  prometheus_workspace_id    = module.observability.prometheus_workspace_id
  container_registry_id      = module.container_registry.id
}
