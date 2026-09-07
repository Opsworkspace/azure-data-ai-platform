variable "resource_group_name" {
  description = "Resource group for the spoke. Created by this module."
  type        = string
}

variable "location" {
  description = "Azure region. Must match the hub it peers to — cross-region spokes are a different design and this module rejects the idea by simply not supporting it."
  type        = string
}

variable "tags" {
  description = "Standard tag set from the naming module."
  type        = map(string)
}

variable "name_prefix" {
  description = "Hyphenated name stem from the naming module."
  type        = string
}

variable "address_space" {
  description = "Spoke address space. A /16 per region per environment. Generous on purpose: AKS with Azure CNI consumes IPs per pod, and running out of address space is a rebuild, not a resize."
  type        = string

  validation {
    condition     = can(cidrhost(var.address_space, 0)) && tonumber(split("/", var.address_space)[1]) <= 20
    error_message = "address_space must be valid CIDR and no smaller than a /20."
  }
}

variable "hub_vnet_id" {
  description = "Resource id of the hub VNet to peer with."
  type        = string
}

variable "hub_vnet_name" {
  description = "Name of the hub VNet, needed to create the return peering."
  type        = string
}

variable "hub_resource_group_name" {
  description = "Resource group of the hub VNet."
  type        = string
}

variable "firewall_private_ip" {
  description = "Private IP of the hub firewall. When null, no default route is written and the spoke uses Azure's default internet path — acceptable only in dev."
  type        = string
  default     = null
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving NSG flow and VNet diagnostics."
  type        = string
  default     = ""
}

variable "enable_databricks_subnets" {
  description = "Create the delegated host/container subnet pair Databricks VNet injection requires. Databricks cannot share a subnet with anything else, so these exist only when needed."
  type        = bool
  default     = true
}
