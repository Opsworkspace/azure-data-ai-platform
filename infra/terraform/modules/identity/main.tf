# ---------------------------------------------------------------------------
# Managed identities and RBAC.
#
# The goal of this module is that the platform contains ZERO application
# credentials. Not "credentials in Key Vault" — zero credentials.
#
# --- how that works ---------------------------------------------------------
#
# A pod needs to read from Cosmos DB. The traditional answer is a connection
# string in a Kubernetes Secret. That secret has to be created, distributed,
# rotated, and kept out of git, and it is valid for anyone who obtains it,
# from anywhere, forever.
#
# Workload Identity Federation removes it entirely:
#
#   1. AKS runs an OIDC issuer. Every pod's service account token is a signed
#      JWT naming its namespace and service account.
#   2. A user-assigned managed identity in Entra is configured to TRUST that
#      issuer, for one specific namespace + service account subject.
#   3. The pod presents its service account token to Entra and receives an
#      Azure access token in exchange.
#   4. That token is scoped, short-lived, and only obtainable by a pod running
#      in the right namespace with the right service account.
#
# There is nothing to steal at rest. An attacker who exfiltrates the entire
# cluster state gets tokens that expire in an hour and cannot be replayed from
# outside the cluster.
#
# --- the RBAC principles this module enforces ------------------------------
#
#   * Least privilege by default. Roles are granted at the narrowest scope
#     that works — a single container, not the resource group.
#   * Built-in roles over custom ones. A custom role is a maintenance burden
#     and drifts from Azure's own updates. Custom roles appear in
#     platform/policies/ only where no built-in role fits.
#   * No Owner, anywhere, for any workload. Owner includes the right to grant
#     roles, which means any principal with Owner can escalate to anything.
#     Contributor plus User Access Administrator is the auditable equivalent
#     when it is genuinely needed, and it is needed far less often than people
#     assume.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

locals {
  # Identities that federate with Kubernetes. An identity with no namespace is
  # a plain managed identity used by something else.
  kubernetes_identities = {
    for k, v in var.workload_identities : k => v
    if v.kubernetes_namespace != null && v.kubernetes_service_account != null
  }

  # Flatten every {identity, role, scope} triple into one map so that a single
  # for_each drives all role assignments. The key must be stable and unique:
  # using the index would mean reordering the list recreates assignments.
  workload_role_assignments = merge([
    for identity_key, identity in var.workload_identities : {
      for ra in identity.role_assignments :
      "${identity_key}|${ra.role_definition_name}|${sha1(ra.scope)}" => {
        identity_key         = identity_key
        role_definition_name = ra.role_definition_name
        scope                = ra.scope
        description          = ra.description
      }
    }
  ]...)

  github_role_assignments = merge([
    for identity_key, identity in var.github_federated_identities : {
      for ra in identity.role_assignments :
      "${identity_key}|${ra.role_definition_name}|${sha1(ra.scope)}" => {
        identity_key         = identity_key
        role_definition_name = ra.role_definition_name
        scope                = ra.scope
      }
    }
  ]...)
}

# --- workload identities ----------------------------------------------------

resource "azurerm_user_assigned_identity" "workload" {
  for_each = var.workload_identities

  name                = "${var.name_prefix}-id-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# The trust relationship. This is the whole mechanism: it says "a token from
# THIS cluster's issuer, for THIS namespace and service account, may become
# this identity". Change any of the three and the exchange stops working.
#
# Note the subject format. It is fixed by the Kubernetes OIDC spec and a typo
# here produces an AADSTS70021 error at runtime that does not name the field.
resource "azurerm_federated_identity_credential" "kubernetes" {
  for_each = var.oidc_issuer_url != "" ? local.kubernetes_identities : {}

  name                = "fic-${each.key}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.workload[each.key].id

  audience = ["api://AzureADTokenExchange"]
  issuer   = var.oidc_issuer_url
  subject  = "system:serviceaccount:${each.value.kubernetes_namespace}:${each.value.kubernetes_service_account}"
}

resource "azurerm_role_assignment" "workload" {
  for_each = local.workload_role_assignments

  principal_id         = azurerm_user_assigned_identity.workload[each.value.identity_key].principal_id
  role_definition_name = each.value.role_definition_name
  scope                = each.value.scope
  description          = each.value.description

  # Managed identity creation is eventually consistent in Entra. Without this,
  # a role assignment created in the same apply intermittently fails with
  # "PrincipalNotFound" — a flaky-apply failure that wastes a lot of time
  # before anyone suspects replication lag.
  principal_type = "ServicePrincipal"
}

# --- GitHub Actions federation (defined, deliberately unused) ---------------
#
# This is exactly how a funded environment would let CI run `terraform plan`
# and `apply` with no stored secret. It is present so the pattern is legible
# and reviewable, and empty so the repository stays undeployable.

resource "azurerm_user_assigned_identity" "github" {
  for_each = var.github_federated_identities

  name                = "${var.name_prefix}-id-gh-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "github" {
  for_each = var.github_federated_identities

  name                = "fic-gh-${each.key}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.github[each.key].id

  audience = ["api://AzureADTokenExchange"]
  issuer   = "https://token.actions.githubusercontent.com"

  # The subject is what pins this credential to one repository AND one
  # trigger. "repo:org/repo:ref:refs/heads/main" cannot be used by a pull
  # request from a fork, which is the attack this format exists to prevent.
  # A wildcard subject here would let any branch in the repo deploy to prod.
  subject = "repo:${each.value.github_org}/${each.value.github_repo}:${each.value.subject}"
}

resource "azurerm_role_assignment" "github" {
  for_each = local.github_role_assignments

  principal_id         = azurerm_user_assigned_identity.github[each.value.identity_key].principal_id
  role_definition_name = each.value.role_definition_name
  scope                = each.value.scope
  principal_type       = "ServicePrincipal"
}
