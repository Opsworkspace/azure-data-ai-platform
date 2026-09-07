# ---------------------------------------------------------------------------
# Outputs.
#
# Deliberately limited to non-sensitive, operationally useful values. Nothing
# here is a secret; the connection strings and keys that a naive output block
# would expose are absent because the platform does not use any.
# ---------------------------------------------------------------------------

output "front_door_hostname" {
  description = "Front Door's generated hostname. The custom domain CNAMEs to this."
  value       = module.front_door.endpoint_hostname
}

output "front_door_id" {
  description = "Front Door resource GUID. Origins verify the X-Azure-FDID header against this to reject traffic that did not come through this Front Door."
  value       = module.front_door.resource_guid
}

output "aks_clusters" {
  description = "Per-region cluster facts an operator needs."
  value = {
    for k, v in module.aks : k => {
      name         = v.name
      private_fqdn = v.private_fqdn
      connect      = v.kube_config_command
    }
  }
}

output "workload_identity_client_ids" {
  description = "Client ids per region per workload. These go into the ServiceAccount annotations. Identifiers, not secrets."
  value = {
    for k, v in module.workload_identity : k => v.workload_identity_client_ids
  }
}

output "cosmos_endpoint" {
  description = "Cosmos account endpoint."
  value       = module.cosmosdb.endpoint
}

output "cosmos_partition_keys" {
  description = "The partition key chosen for each container. Surfaced as an output because it is the single least reversible decision in the platform and should be visible without reading the code."
  value       = module.cosmosdb.container_names
}

output "lakehouse_abfss_paths" {
  description = "abfss:// URIs for each medallion layer, for Unity Catalog external locations and notebooks."
  value       = module.lakehouse.abfss_paths
}

output "container_registry_login_server" {
  description = "Image prefix for every Kubernetes manifest."
  value       = module.container_registry.login_server
}

output "grafana_endpoint" {
  description = "Grafana URL."
  value       = module.observability.grafana_endpoint
}

output "error_budget_minutes_per_month" {
  description = "Downtime the SLO permits per 30 days. Computed from slo_target so the dashboards and the Terraform cannot disagree."
  value       = module.observability.error_budget_minutes_per_month
}

output "firewall_egress_ips" {
  description = "The public IPs all outbound traffic leaves from, per region. These are the addresses a partner would allow-list."
  value       = { for k, v in module.hub : k => v.firewall_public_ip }
}

output "network_plan" {
  description = "The full address plan, per region. Useful for documentation and for confirming no overlap before adding a region."
  value = {
    for k, v in local.regions : k => {
      location   = v.location
      hub_cidr   = v.hub_cidr
      spoke_cidr = v.spoke_cidr
      subnets    = module.spoke[k].subnet_cidrs
    }
  }
}
