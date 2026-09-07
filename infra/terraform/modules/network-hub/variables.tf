variable "resource_group_name" {
  description = "Resource group to create the hub in. Created by this module."
  type        = string
}

variable "location" {
  description = "Azure region for the hub."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource, from the naming module."
  type        = map(string)
}

variable "name_prefix" {
  description = "Hyphenated name stem from the naming module, e.g. purple-net-prod-eus2."
  type        = string
}

variable "address_space" {
  description = "Hub address space. A /20 is ample: the hub holds only shared network appliances, never workloads. Subnets are carved from it deterministically so no operator hand-allocates a CIDR."
  type        = string

  validation {
    condition     = can(cidrhost(var.address_space, 0)) && tonumber(split("/", var.address_space)[1]) <= 22
    error_message = "address_space must be valid CIDR and no smaller than a /22 — AzureFirewallSubnet alone requires a /26."
  }
}

variable "deploy_firewall" {
  description = "Deploy Azure Firewall. Billed per hour per region whether or not traffic flows, so dev sets this false and relies on NSGs plus the default internet route. The cost/control trade-off is documented in docs/architecture/08-cost-and-finops.md."
  type        = bool
  default     = true
}

variable "firewall_sku_tier" {
  description = "Standard or Premium. Premium adds TLS inspection, IDPS and URL filtering; it roughly doubles the hourly cost."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.firewall_sku_tier)
    error_message = "firewall_sku_tier must be Standard or Premium."
  }
}

variable "deploy_bastion" {
  description = "Deploy Azure Bastion. The only sanctioned interactive path to a private node — there are no public IPs on any VM or node pool in this platform."
  type        = bool
  default     = true
}

variable "bastion_sku" {
  description = "Basic or Standard. Standard is required for native client (RDP/SSH over az CLI) and IP-based connection."
  type        = string
  default     = "Standard"
}

variable "log_analytics_workspace_id" {
  description = "Workspace that receives firewall, bastion and NSG diagnostics. Empty disables diagnostic settings, which is only acceptable in dev."
  type        = string
  default     = ""
}

variable "allowed_egress_fqdns" {
  description = "FQDNs the platform is permitted to reach outbound through the firewall. This is an allow-list, not a block-list: anything absent is denied. Keeping it in code means an egress change is a reviewed pull request."
  type        = list(string)
  default = [
    "*.azurecr.io",             # container image pull
    "*.blob.core.windows.net",  # image layers, Databricks artefacts
    "mcr.microsoft.com",        # Microsoft container registry
    "*.data.mcr.microsoft.com", # MCR data plane
    "management.azure.com",     # ARM control plane
    "login.microsoftonline.com",
    "packages.microsoft.com",
    "acs-mirror.azureedge.net", # AKS node bootstrap
    "*.azuredatabricks.net",    # Databricks control plane
    "*.pypi.org",               # Python packages for Databricks jobs
    "files.pythonhosted.org",
  ]
}
