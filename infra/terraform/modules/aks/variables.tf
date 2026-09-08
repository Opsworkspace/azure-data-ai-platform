variable "name" {
  description = "Cluster name from the naming module."
  type        = string
}

variable "node_resource_group_name" {
  description = "Name for the AKS-managed node resource group. Naming it explicitly avoids the unreadable MC_<rg>_<cluster>_<region> default and makes cost queries legible."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group for the cluster object itself."
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

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. 1.31. AKS supports N-2, so a version is a ~12 month commitment before a forced upgrade. Pinned, not 'latest': a control plane that upgrades itself during an incident is a bad day."
  type        = string
  default     = "1.31"
}

variable "sku_tier" {
  description = "Free, Standard or Premium. Standard buys a 99.95% control-plane SLA (99.99% with availability zones) for ~$0.10/hour; Free has no SLA at all. Any cluster with a production SLO must be Standard — the control plane is a dependency of every pod start, scale event and probe."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "system_subnet_id" {
  description = "Subnet for the system node pool."
  type        = string
}

variable "user_subnet_id" {
  description = "Subnet for the application node pool."
  type        = string
}

variable "ai_subnet_id" {
  description = "Subnet for the AI/GPU node pool."
  type        = string
}

variable "pod_cidr" {
  description = "Address space for pods in overlay mode. This is NOT part of the VNet — it is an overlay network, so it can be reused across clusters and does not consume VNet addresses. Must not overlap the VNet or the service CIDR."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Address space for Kubernetes Service ClusterIPs. Virtual, never routed, must not overlap anything else the cluster can reach."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "CoreDNS ClusterIP. Must be inside service_cidr and is conventionally the tenth address."
  type        = string
  default     = "172.16.0.10"
}

variable "admin_group_object_ids" {
  description = "Entra group object ids granted cluster-admin. Placeholder all-zero GUID in this repository. Groups, never individual users: a person who leaves should lose access by leaving the group, not by someone remembering to edit Terraform."
  type        = list(string)
  default     = ["00000000-0000-0000-0000-000000000000"]
}

variable "system_node_pool" {
  description = "System pool sizing. Runs only cluster-critical add-ons (CoreDNS, metrics-server, CSI drivers)."
  type = object({
    vm_size    = optional(string, "Standard_D4ds_v5")
    min_count  = optional(number, 3)
    max_count  = optional(number, 6)
    zones      = optional(list(string), ["1", "2", "3"])
    os_disk_gb = optional(number, 128)
  })
  default = {}
}

variable "user_node_pool" {
  description = "Application pool sizing."
  type = object({
    vm_size    = optional(string, "Standard_D8ds_v5")
    min_count  = optional(number, 3)
    max_count  = optional(number, 30)
    zones      = optional(list(string), ["1", "2", "3"])
    os_disk_gb = optional(number, 256)
    spot_pool  = optional(bool, false)
  })
  default = {}
}

variable "ai_node_pool" {
  description = "AI/inference pool. GPU SKUs are expensive and quota-limited; min_count 0 means it scales to nothing when idle."
  type = object({
    enabled    = optional(bool, false)
    vm_size    = optional(string, "Standard_NC4as_T4_v3")
    min_count  = optional(number, 0)
    max_count  = optional(number, 4)
    zones      = optional(list(string), ["1", "2", "3"])
    os_disk_gb = optional(number, 256)
  })
  default = {}
}

variable "log_analytics_workspace_id" {
  description = "Workspace for Container Insights and control-plane logs."
  type        = string
}

variable "prometheus_workspace_id" {
  description = "Azure Monitor workspace for managed Prometheus scraping. Empty disables it."
  type        = string
  default     = ""
}

variable "container_registry_id" {
  description = "ACR resource id. The kubelet identity is granted AcrPull on it, which is what removes the need for an imagePullSecret."
  type        = string
  default     = ""
}

# tflint-ignore: terraform_unused_declarations
# Deliberately declared and not consumed: see the description. Kept so that
# enabling a public API server later is a change to this module rather than
# a change to every caller's variable list.
variable "authorized_ip_ranges" {
  description = "CIDRs allowed to reach the PUBLIC API server. Empty and unused here, because the cluster is private — the API server has no public endpoint to restrict."
  type        = list(string)
  default     = []
}

variable "maintenance_day" {
  description = "Day of week for the auto-upgrade maintenance window."
  type        = string
  default     = "Sunday"
}
