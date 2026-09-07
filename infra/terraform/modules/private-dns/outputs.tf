output "resource_group_name" {
  description = "Resource group containing the zones."
  value       = azurerm_resource_group.dns.name
}

output "zone_ids" {
  description = "Map of zone name to resource id. Every module that creates a private endpoint looks its zone up here rather than constructing the id."
  value       = { for name, z in azurerm_private_dns_zone.zones : name => z.id }
}

output "zone_names" {
  description = "The set of zone names created."
  value       = keys(azurerm_private_dns_zone.zones)
}
