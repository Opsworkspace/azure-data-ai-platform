variable "resource_group_name" {
  description = "Resource group holding the private DNS zones. Deliberately a shared, long-lived group — see the note on zone ownership in main.tf."
  type        = string
}

variable "location" {
  description = "Region for the resource group. Private DNS zones themselves are global; only their resource group has a location."
  type        = string
}

variable "tags" {
  description = "Standard tag set."
  type        = map(string)
}

variable "vnet_links" {
  description = "VNets that should resolve these zones, as a map of link name to VNet resource id. Every VNet whose workloads call a private endpoint must appear here, including the hub if the firewall's DNS proxy is used."
  type        = map(string)
}

variable "enabled_zones" {
  description = "Which zone groups to create. Creating a zone that no private endpoint uses is harmless but noisy; creating one that IS needed and forgetting it produces the single most confusing failure mode in Azure private networking — the client resolves the PUBLIC IP and then times out against a firewall that never sees the packet."
  type        = list(string)
  default = [
    "storage_blob",
    "storage_dfs",
    "key_vault",
    "container_registry",
    "cosmos_sql",
    "ai_search",
    "openai",
    "databricks",
    "monitor",
  ]
}
