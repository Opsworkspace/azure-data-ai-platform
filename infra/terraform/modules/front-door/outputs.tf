output "profile_id" {
  description = "Front Door profile resource id."
  value       = azurerm_cdn_frontdoor_profile.this.id
}

output "endpoint_hostname" {
  description = "The generated <name>.z01.azurefd.net hostname. A CNAME from the real custom domain points here."
  value       = azurerm_cdn_frontdoor_endpoint.this.host_name
}

output "waf_policy_id" {
  description = "WAF policy resource id."
  value       = azurerm_cdn_frontdoor_firewall_policy.this.id
}

output "origin_group_id" {
  description = "Origin group id, for attaching further routes."
  value       = azurerm_cdn_frontdoor_origin_group.api.id
}

output "resource_guid" {
  description = "Front Door's resource GUID. Origins that restrict access by the X-Azure-FDID header compare against this value, which is how an origin proves traffic came through YOUR Front Door and not someone else's."
  value       = azurerm_cdn_frontdoor_profile.this.resource_guid
}
