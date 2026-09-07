variable "name" {
  description = "Cosmos DB account name from the naming module. Globally unique."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "location" {
  description = "Primary region — the write region when multi-region writes are off, and failover priority 0 when they are on."
  type        = string
}

variable "secondary_locations" {
  description = "Additional regions, in failover priority order. Empty means single-region, which is the correct dev shape."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Standard tag set."
  type        = map(string)
}

variable "consistency_level" {
  description = "Strong, BoundedStaleness, Session, ConsistentPrefix or Eventual. Session is the default here and the right answer for most applications — see the long note in main.tf before changing it."
  type        = string
  default     = "Session"

  validation {
    condition     = contains(["Strong", "BoundedStaleness", "Session", "ConsistentPrefix", "Eventual"], var.consistency_level)
    error_message = "Invalid consistency level."
  }
}

variable "enable_multi_region_writes" {
  description = "Multi-region writes. Roughly doubles the RU cost of every write and introduces conflict resolution, in exchange for write availability during a regional outage. Only true where the SLO genuinely demands it."
  type        = bool
  default     = false
}

variable "zone_redundant" {
  description = "Spread each region's replicas across availability zones. Adds cost per region; required to claim zone-fault tolerance."
  type        = bool
  default     = true
}

variable "enable_serverless" {
  description = "Serverless capacity mode: pay per request, no minimum. Ideal for dev, unusable in production (no multi-region, no autoscale, 5000 RU/s ceiling per container)."
  type        = bool
  default     = false
}

variable "backup_tier" {
  description = "Continuous7Days or Continuous30Days. Continuous backup gives point-in-time restore to any second in the window, which is the only backup mode that helps against a bad deploy that corrupts data gradually."
  type        = string
  default     = "Continuous30Days"
}

variable "database_name" {
  description = "SQL API database name."
  type        = string
  default     = "purple"
}

variable "containers" {
  description = <<-EOT
    Container definitions. The partition_key_path is the single most
    consequential choice in a Cosmos design and cannot be changed without
    recreating the container and migrating data.
  EOT
  type = map(object({
    partition_key_path   = string
    max_throughput       = optional(number, 4000)
    default_ttl_seconds  = optional(number, -1)
    unique_key_paths     = optional(list(string), [])
    excluded_index_paths = optional(list(string), [])
  }))
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the private endpoint NIC."
  type        = string
}

variable "private_dns_zone_ids" {
  description = "Zone ids for privatelink.documents.azure.com."
  type        = list(string)
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving Cosmos diagnostics. Empty disables them."
  type        = string
  default     = ""
}
