output "front_door_hostname" {
  description = "Front Door hostname for the staging API."
  value       = module.front_door.endpoint_hostname
}

output "aks_cluster" {
  description = "How to connect to the staging cluster."
  value       = module.aks["primary"].kube_config_command
}

output "workload_identity_client_ids" {
  description = "Client ids for ServiceAccount annotations."
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

output "firewall_egress_ip" {
  description = "The single public IP staging egresses from."
  value       = module.hub["primary"].firewall_public_ip
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

output "gaps_versus_prod" {
  description = "What stage still cannot validate. Stated explicitly so nobody assumes a green stage run proves multi-region behaviour."
  value = {
    regions                   = 1
    cross_region_failover     = "NOT validated here — exercised by game day in production"
    cosmos_multi_region_write = "NOT validated here — single write region"
    global_peering_behaviour  = "NOT validated here"
    validated_that_dev_cannot = "egress allow-list, WAF false positives, autoscale and RU behaviour, zone redundancy, alert thresholds"
  }
}
