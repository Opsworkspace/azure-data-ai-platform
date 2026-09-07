variable "name" {
  description = "Front Door profile name from the naming module."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group. Front Door is a global resource; its resource group location is metadata only."
  type        = string
}

variable "tags" {
  description = "Standard tag set."
  type        = map(string)
}

variable "sku_name" {
  description = "Standard_AzureFrontDoor or Premium_AzureFrontDoor. Premium is required for managed WAF rule sets, bot protection, and Private Link origins — all three of which this design depends on."
  type        = string
  default     = "Premium_AzureFrontDoor"

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.sku_name)
    error_message = "sku_name must be Standard_AzureFrontDoor or Premium_AzureFrontDoor."
  }
}

variable "origins" {
  description = <<-EOT
    Regional backends, keyed by region name. Each is one AKS ingress endpoint.

    priority and weight together define the traffic policy:
      equal priority + equal weight  -> active/active, latency-routed
      different priority             -> active/passive failover
  EOT
  type = map(object({
    host_name = string
    priority  = optional(number, 1)
    weight    = optional(number, 500)
    private_link = optional(object({
      location               = string
      private_link_target_id = string
      request_message        = optional(string, "Front Door origin link")
    }))
  }))
}

variable "custom_domain" {
  description = "Custom hostname served by Front Door. A documentation domain in this repository."
  type        = string
  default     = "api.purple.example.com"
}

variable "waf_mode" {
  description = "Detection or Prevention. Detection LOGS matches without blocking, and is how a WAF should always be introduced — going straight to Prevention on an unprofiled application blocks real users on day one."
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "waf_mode must be Detection or Prevention."
  }
}

variable "rate_limit_threshold" {
  description = "Requests per minute per client IP before rate limiting engages. Front Door evaluates this over a fixed 1-minute window."
  type        = number
  default     = 1000
}

variable "health_probe_path" {
  description = "Path Front Door probes on each origin. Must be a DEEP health check that exercises the origin's own dependencies — a path that returns 200 from a process with a dead database defeats the entire failover design."
  type        = string
  default     = "/healthz/ready"
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving Front Door access and WAF logs."
  type        = string
  default     = ""
}
