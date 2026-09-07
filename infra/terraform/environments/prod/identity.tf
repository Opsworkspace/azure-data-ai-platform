# ------------------------------------------------------------- 10. identity ---
#
# One identity module per region, because each federates with a different AKS
# cluster's OIDC issuer. The Kubernetes manifests in platform/kubernetes/ are
# otherwise identical between regions — only the client id annotation differs,
# which is why it is injected by Kustomize rather than committed.
#
# Read the role assignments below as the platform's complete authorisation
# model. Every one is scoped to a single resource, and there is no Contributor
# or Owner anywhere.

module "workload_identity" {
  source   = "../../modules/identity"
  for_each = local.regions

  resource_group_name = azurerm_resource_group.data[each.key].name
  location            = each.value.location
  name_prefix         = module.naming_platform[each.key].base
  tags                = module.naming_platform[each.key].tags

  oidc_issuer_url = module.aks[each.key].oidc_issuer_url

  workload_identities = {
    # --- the public API -----------------------------------------------------
    api = {
      kubernetes_namespace       = "purple"
      kubernetes_service_account = "purple-api"

      role_assignments = [
        {
          role_definition_name = "Cosmos DB Built-in Data Contributor"
          scope                = module.cosmosdb.id
          description          = "Read and write user, dataset and conversation documents."
        },
        {
          role_definition_name = "Key Vault Secrets User"
          scope                = module.key_vault[each.key].id
          description          = "Read secrets mounted by the CSI driver. Read only: the API never writes a secret."
        },
        {
          role_definition_name = "Cognitive Services OpenAI User"
          scope                = module.ai_services[each.key].openai_id
          description          = "Call the chat and embedding deployments. 'User' can invoke models but cannot create or delete deployments."
        },
        {
          role_definition_name = "Search Index Data Reader"
          scope                = module.ai_services[each.key].search_id
          description          = "Query the vector index. Reader, not Contributor: the API retrieves, it never writes to the index."
        },
      ]
    }

    # --- the async worker ---------------------------------------------------
    worker = {
      kubernetes_namespace       = "purple"
      kubernetes_service_account = "purple-worker"

      role_assignments = [
        {
          role_definition_name = "Cosmos DB Built-in Data Contributor"
          scope                = module.cosmosdb.id
          description          = "Update job state and write idempotency records."
        },
        {
          role_definition_name = "Storage Blob Data Contributor"
          scope                = module.lakehouse.id
          description          = "Write uploaded datasets into the bronze layer."
        },
        {
          role_definition_name = "Search Index Data Contributor"
          scope                = module.ai_services[each.key].search_id
          description          = "Write embeddings into the index. This is the ONLY identity that may write to the index."
        },
        {
          role_definition_name = "Cognitive Services OpenAI User"
          scope                = module.ai_services[each.key].openai_id
          description          = "Generate embeddings for ingested documents."
        },
        {
          role_definition_name = "Key Vault Secrets User"
          scope                = module.key_vault[each.key].id
        },
      ]
    }

    # --- read-only identity for diagnostics ---------------------------------
    # Used by the debug tooling in tools/. Deliberately has no write role
    # anywhere, so it can be granted more freely to engineers investigating an
    # incident without expanding the blast radius.
    diagnostics = {
      kubernetes_namespace       = "purple-system"
      kubernetes_service_account = "purple-diagnostics"

      role_assignments = [
        {
          role_definition_name = "Cosmos DB Account Reader Role"
          scope                = module.cosmosdb.id
          description          = "Read Cosmos metrics and metadata. Grants NO data-plane read."
        },
        {
          role_definition_name = "Monitoring Reader"
          scope                = module.observability.log_analytics_workspace_id
        },
      ]
    }
  }

  # Empty, and that is the point. See docs/00-safety-and-placeholders.md
  # Rule 1: no pipeline in this repository holds a deployment identity.
  github_federated_identities = {}
}

# --- Grafana's own permissions ----------------------------------------------
# Grafana queries Azure Monitor as itself. Monitoring Reader at subscription
# scope is the narrowest role that lets it discover and query every resource's
# metrics; anything narrower means adding a role assignment per resource.
resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Monitoring Reader"
  principal_id         = module.observability.grafana_identity_principal_id
  principal_type       = "ServicePrincipal"

  description = "Grafana reads metrics and logs across the subscription. Read-only by definition."
}

# --- AKS Key Vault CSI driver ------------------------------------------------
# The CSI driver has its own identity, separate from both the cluster identity
# and the workload identities. It is the principal that actually fetches the
# secret from Key Vault before projecting it into the pod.
resource "azurerm_role_assignment" "csi_key_vault_secrets_user" {
  for_each = local.regions

  scope                = module.key_vault[each.key].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.aks[each.key].key_vault_secrets_provider_identity_object_id
  principal_type       = "ServicePrincipal"

  description = "Lets the Secrets Store CSI driver read secrets to mount into pods."
}
