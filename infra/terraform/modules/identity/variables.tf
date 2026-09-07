variable "resource_group_name" {
  description = "Resource group holding the managed identities."
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

variable "name_prefix" {
  description = "Hyphenated name stem from the naming module."
  type        = string
}

variable "workload_identities" {
  description = <<-EOT
    One managed identity per workload that needs to authenticate to Azure.

    Keyed by a short workload name. Each entry declares the Kubernetes service
    account it federates with and the Azure roles it needs. Both are declared
    together on purpose: an identity whose permissions live in a different file
    from its trust relationship is an identity nobody can audit.
  EOT
  type = map(object({
    # The AKS namespace and service account allowed to assume this identity.
    # Null means the identity is not used from Kubernetes (e.g. a CI identity).
    kubernetes_namespace       = optional(string)
    kubernetes_service_account = optional(string)

    # Azure RBAC role assignments, as a list of {role, scope} pairs.
    role_assignments = optional(list(object({
      role_definition_name = string
      scope                = string
      description          = optional(string, "")
    })), [])
  }))
  default = {}
}

variable "oidc_issuer_url" {
  description = "The AKS cluster's OIDC issuer URL, from the aks module. Required if any workload identity federates with Kubernetes."
  type        = string
  default     = ""
}

variable "github_federated_identities" {
  description = <<-EOT
    Federated credentials for GitHub Actions, so a pipeline can authenticate to
    Azure with NO stored secret at all.

    NOT ENABLED in this repository. It is defined, documented and left empty,
    because a repository that cannot deploy cannot leak a deployment identity.
    See docs/00-safety-and-placeholders.md, Rule 1.
  EOT
  type = map(object({
    github_org  = string
    github_repo = string
    # "environment:prod", "ref:refs/heads/main", or "pull_request".
    subject = string
    role_assignments = optional(list(object({
      role_definition_name = string
      scope                = string
    })), [])
  }))
  default = {}
}
