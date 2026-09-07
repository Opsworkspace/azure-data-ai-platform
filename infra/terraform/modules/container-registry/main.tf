# ---------------------------------------------------------------------------
# Azure Container Registry.
#
# The registry is a supply-chain control point, not just a file store. Three
# things follow from that:
#
#   * admin_enabled = false. The admin account is a single shared username and
#     password with push rights to every repository. It cannot be scoped,
#     rotated per consumer, or attributed to a person. It exists for demos.
#     AKS pulls with its kubelet managed identity and AcrPull; CI pushes with
#     a workload-identity federated credential and AcrPush.
#
#   * Private endpoint plus public_network_access_enabled = false. An image is
#     a description of your production environment: base images, installed
#     packages, sometimes configuration. A public registry with anonymous pull
#     disabled is still an information-disclosure surface.
#
#   * Geo-replication to every region that runs workloads. A pull is on the
#     critical path of every pod start, including the pod starts that happen
#     during a regional failover.
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

resource "azurerm_container_registry" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  tags                = var.tags

  admin_enabled = false

  public_network_access_enabled = false
  # Data endpoints give each replica region its own dedicated data hostname,
  # which is what lets a private endpoint in region B serve pulls from the
  # replica in region B rather than proxying to the primary.
  data_endpoint_enabled  = var.sku == "Premium"
  anonymous_pull_enabled = false

  # Premium-only. Zone redundancy on the registry itself, plus per-replica.
  zone_redundancy_enabled = var.sku == "Premium"

  # Untagged manifests are deleted after this many days. Premium only.
  retention_policy_in_days = var.sku == "Premium" ? var.retention_days : null

  # Blocks `az acr import` and cross-registry export out of this registry.
  # Turning it off is a deliberate exfiltration control; it also means a
  # legitimate migration needs a policy change, which is the point.
  export_policy_enabled = false

  dynamic "georeplications" {
    for_each = var.sku == "Premium" ? var.georeplication_locations : []
    content {
      location                  = georeplications.value
      zone_redundancy_enabled   = true
      regional_endpoint_enabled = true
      tags                      = var.tags
    }
  }

  network_rule_set {
    default_action = "Deny"
  }

  identity {
    # A system-assigned identity on the registry itself, used for
    # customer-managed key encryption and for ACR Tasks if they are ever
    # enabled. Present now so enabling either later is not a recreate.
    type = "SystemAssigned"
  }
}

resource "azurerm_private_endpoint" "this" {
  name                = "${var.name}-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name}-psc"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.private_dns_zone_ids
  }
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Who pushed what, and when. During an incident the question "what changed"
  # is usually answered by this log rather than by the deployment pipeline.
  enabled_log { category = "ContainerRegistryRepositoryEvents" }
  enabled_log { category = "ContainerRegistryLoginEvents" }

  enabled_metric { category = "AllMetrics" }
}
