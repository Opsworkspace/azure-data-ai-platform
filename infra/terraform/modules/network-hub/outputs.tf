output "resource_group_name" {
  description = "Name of the hub resource group."
  value       = azurerm_resource_group.hub.name
}

output "vnet_id" {
  description = "Hub VNet resource id. Spokes peer to this."
  value       = azurerm_virtual_network.hub.id
}

output "vnet_name" {
  description = "Hub VNet name."
  value       = azurerm_virtual_network.hub.name
}

output "address_space" {
  description = "Hub address space, echoed so spokes can write NSG rules against it without hard-coding."
  value       = var.address_space
}

output "shared_subnet_id" {
  description = "Subnet for shared services such as a DNS private resolver."
  value       = azurerm_subnet.shared.id
}

output "firewall_private_ip" {
  description = "Private IP of the firewall. Spoke route tables send 0.0.0.0/0 here. Null when the firewall is not deployed, which is the signal spokes use to fall back to a direct internet route."
  value       = var.deploy_firewall ? azurerm_firewall.hub[0].ip_configuration[0].private_ip_address : null
}

output "firewall_public_ip" {
  description = "The single egress IP for the region. This is the address a partner would allow-list, and the reason a NAT-gateway-per-spoke design was rejected — see docs/adr/0005-egress-through-firewall.md."
  value       = var.deploy_firewall ? azurerm_public_ip.firewall[0].ip_address : null
}

output "firewall_policy_id" {
  description = "Firewall policy id, so a child policy can be attached per environment."
  value       = var.deploy_firewall ? azurerm_firewall_policy.hub[0].id : null
}

output "bastion_id" {
  description = "Bastion host id."
  value       = var.deploy_bastion ? azurerm_bastion_host.hub[0].id : null
}
