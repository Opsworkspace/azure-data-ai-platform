variable "openai_name" {
  description = "Azure OpenAI account name from the naming module."
  type        = string
}

variable "search_name" {
  description = "AI Search service name from the naming module."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "location" {
  description = "Azure region. Model availability varies sharply by region — a model deployment that works in eastus2 may be unavailable in the paired region, which is a real constraint on active-active AI serving."
  type        = string
}

variable "tags" {
  description = "Standard tag set."
  type        = map(string)
}

variable "model_deployments" {
  description = <<-EOT
    Models to deploy. Capacity is in thousands of tokens per minute (TPM) and
    is the throughput quota, not a machine size — it is subscription- and
    region-limited, and requesting more is a support ticket, not a Terraform
    change.
  EOT
  type = map(object({
    model_name      = string
    model_version   = string
    sku_name        = optional(string, "GlobalStandard")
    capacity        = optional(number, 10)
    rai_policy_name = optional(string)
  }))
  default = {}
}

variable "search_sku" {
  description = "free, basic, standard, standard2, standard3. Only basic and above support private endpoints; standard and above support the replica counts needed for a read SLA."
  type        = string
  default     = "standard"
}

variable "search_replica_count" {
  description = "Replicas serve queries. Azure requires 2 replicas for a 99.9% read SLA and 3 for a 99.9% read/write SLA — a single replica has no SLA at all."
  type        = number
  default     = 2
}

variable "search_partition_count" {
  description = "Partitions hold the index and scale storage and write throughput. Total units billed = replicas x partitions, so this multiplies cost."
  type        = number
  default     = 1
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the private endpoint NICs."
  type        = string
}

variable "openai_private_dns_zone_ids" {
  description = "Zone ids for privatelink.openai.azure.com and privatelink.cognitiveservices.azure.com."
  type        = list(string)
}

variable "search_private_dns_zone_ids" {
  description = "Zone ids for privatelink.search.windows.net."
  type        = list(string)
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving diagnostics."
  type        = string
  default     = ""
}
