output "aks_cluster" {
  description = "How to connect to the dev cluster. Requires network line-of-sight to the private API server."
  value       = module.aks["primary"].kube_config_command
}

output "workload_identity_client_ids" {
  description = "Client ids for the ServiceAccount annotations."
  value       = module.workload_identity["primary"].workload_identity_client_ids
}

output "cosmos_endpoint" {
  description = "Cosmos account endpoint."
  value       = module.cosmosdb.endpoint
}

output "lakehouse_abfss_paths" {
  description = "abfss:// URIs per medallion layer."
  value       = module.lakehouse.abfss_paths
}

output "container_registry_login_server" {
  description = "Image prefix for manifests."
  value       = module.container_registry.login_server
}

output "network_plan" {
  description = "Address plan for this environment."
  value = {
    for k, v in local.regions : k => {
      location   = v.location
      hub_cidr   = v.hub_cidr
      spoke_cidr = v.spoke_cidr
      subnets    = module.spoke[k].subnet_cidrs
    }
  }
}

output "cost_trades_versus_prod" {
  description = "The deliberate differences from production, as data rather than as a comment. Surfaced so a reviewer can diff environments without reading both configurations."
  value = {
    regions             = 1
    azure_firewall      = "not deployed — no egress allow-list enforcement"
    front_door_and_waf  = "not deployed — WAF rules unexercised"
    cosmos_mode         = "serverless, single region"
    aks_sku_tier        = "Free — no control-plane SLA"
    storage_replication = "LRS"
    zone_redundancy     = "none"
    alerting            = "disabled"
    unchanged_from_prod = "private endpoints, workload identity, RBAC model, network shape, Cosmos partition keys"
  }
}
