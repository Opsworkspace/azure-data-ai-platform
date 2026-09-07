# ---------------------------------------------------------------------------
# Azure OpenAI and AI Search — the retrieval-augmented generation (RAG) plane.
#
# How the AI assistant in this platform works, and why both services exist:
#
#   1. A user's documents land in the lakehouse (gold layer).
#   2. A Databricks job chunks them and calls the EMBEDDING model to turn each
#      chunk into a vector.
#   3. Those vectors go into an AI Search index alongside the original text.
#   4. At query time the user's question is embedded with the same model, AI
#      Search returns the nearest chunks, and those chunks are put into the
#      prompt sent to the CHAT model.
#
# Step 4 is the whole point. The chat model never sees the corpus; it sees a
# handful of retrieved passages. That is what makes per-user data isolation
# possible — the filter applied at search time is the security boundary, and
# it is enforced before any text reaches the model.
#
# Getting this wrong is the defining security failure of enterprise RAG: an
# index without a per-user filter will happily return another tenant's
# documents, and the model will summarise them convincingly.
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

resource "azurerm_cognitive_account" "openai" {
  name                = var.openai_name
  resource_group_name = var.resource_group_name
  location            = var.location
  kind                = "OpenAI"
  sku_name            = "S0"
  tags                = var.tags

  # A custom subdomain is REQUIRED for both Entra token authentication and
  # private endpoints. Without it the account is only reachable at the shared
  # regional endpoint, which cannot be privately linked and only accepts key
  # authentication. It cannot be added after creation.
  custom_subdomain_name = var.openai_name

  public_network_access_enabled = false
  local_auth_enabled            = false

  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}

# --- model deployments ------------------------------------------------------
# A "deployment" is a named endpoint bound to a model version with a throughput
# quota. Applications reference the DEPLOYMENT name, not the model name, which
# is what makes a model upgrade a deployment change rather than a code change.
#
# Deployments are created serially on purpose: Azure OpenAI rejects concurrent
# deployment operations on the same account with a conflict error that
# Terraform surfaces as a generic 409.

resource "azurerm_cognitive_deployment" "models" {
  for_each = var.model_deployments

  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = each.value.model_name
    version = each.value.model_version
  }

  sku {
    # GlobalStandard routes to capacity anywhere in the geography, giving much
    # higher available throughput than a region-pinned Standard deployment.
    # The trade-off is data residency: inference may happen outside the
    # region. For a platform with a stated US dual-region residency
    # requirement, DataZoneStandard is the compliant choice.
    name     = each.value.sku_name
    capacity = each.value.capacity
  }

  # Content filtering policy. Null uses the Microsoft default, which blocks
  # the highest-severity categories. A custom policy is defined in the portal
  # or via the RAI API and referenced here by name.
  rai_policy_name = each.value.rai_policy_name

  lifecycle {
    # Model versions are retired by Microsoft on a published schedule, and an
    # auto-upgrade can change behaviour under a running application. The
    # version is pinned; upgrading is a deliberate, tested change.
    ignore_changes = []
  }
}

resource "azurerm_private_endpoint" "openai" {
  name                = "${var.openai_name}-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.openai_name}-psc"
    private_connection_resource_id = azurerm_cognitive_account.openai.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.openai_private_dns_zone_ids
  }
}

# --- AI Search --------------------------------------------------------------

resource "azurerm_search_service" "this" {
  name                = var.search_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.search_sku
  tags                = var.tags

  replica_count   = var.search_replica_count
  partition_count = var.search_partition_count

  public_network_access_enabled = false

  # API keys disabled; every caller uses Entra. Search has two distinct role
  # families that are easy to confuse: the CONTROL plane roles (Search Service
  # Contributor — manage indexes) and the DATA plane roles (Search Index Data
  # Reader / Contributor — read and write documents). An application needs the
  # data plane roles only.
  local_authentication_enabled = false
  authentication_failure_mode  = null

  # Semantic ranking re-ranks the top ~50 vector results with a language model
  # trained for relevance. It measurably improves RAG answer quality and is
  # billed per query, so it is a deliberate cost.
  semantic_search_sku = "standard"

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_private_endpoint" "search" {
  name                = "${var.search_name}-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.search_name}-psc"
    private_connection_resource_id = azurerm_search_service.this.id
    subresource_names              = ["searchService"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.search_private_dns_zone_ids
  }
}

# Search reaches OpenAI to generate embeddings for integrated vectorisation.
# It authenticates as itself, so there is no key to store.
resource "azurerm_role_assignment" "search_to_openai" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_search_service.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"

  description = "Allows AI Search's integrated vectorisation to call the embedding deployment."
}

resource "azurerm_monitor_diagnostic_setting" "openai" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_cognitive_account.openai.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Audit and RequestResponse together answer "which user's request produced
  # this output". RequestResponse logs prompts and completions, so it is
  # subject to the same data-classification rules as the data itself —
  # enabling it in production requires a documented retention decision.
  enabled_log { category = "Audit" }
  enabled_log { category = "RequestResponse" }

  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_monitor_diagnostic_setting" "search" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_search_service.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "OperationLogs" }

  enabled_metric { category = "AllMetrics" }
}
