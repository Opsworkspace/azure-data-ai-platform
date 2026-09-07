variable "name" {
  description = "Storage account name from the naming module: 24 chars, lowercase alphanumeric."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Standard tag set."
  type        = map(string)
}

variable "replication_type" {
  description = "LRS, ZRS, GRS or GZRS. GZRS is zone-redundant locally AND geo-replicated, which is what a lakehouse backing a 99.95% service needs. LRS is acceptable in dev only."
  type        = string
  default     = "GZRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS", "RAGRS", "RAGZRS"], var.replication_type)
    error_message = "replication_type must be one of LRS, ZRS, GRS, GZRS, RAGRS, RAGZRS."
  }
}

variable "medallion_containers" {
  description = "Filesystems for the medallion architecture. Separate containers rather than separate folders, because container is the boundary at which Unity Catalog external locations and RBAC are granted."
  type        = list(string)
  default     = ["bronze", "silver", "gold", "checkpoints", "unity-catalog-metastore"]
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the private endpoint NICs."
  type        = string
}

variable "blob_private_dns_zone_ids" {
  description = "Zone ids for privatelink.blob.core.windows.net."
  type        = list(string)
}

variable "dfs_private_dns_zone_ids" {
  description = "Zone ids for privatelink.dfs.core.windows.net. A Gen2 lakehouse needs BOTH blob and dfs endpoints: Spark's abfss:// driver uses dfs, most SDKs use blob."
  type        = list(string)
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving storage diagnostics. Empty disables them."
  type        = string
  default     = ""
}

variable "delete_retention_days" {
  description = "Soft-delete window for blobs and containers. Protects against the most common data loss cause in a lakehouse: a job that writes to the wrong path with overwrite mode."
  type        = number
  default     = 30
}

variable "enable_lifecycle_management" {
  description = "Tier bronze data to cool and then cold storage as it ages. The single highest-leverage storage cost control — see docs/architecture/08-cost-and-finops.md."
  type        = bool
  default     = true
}
