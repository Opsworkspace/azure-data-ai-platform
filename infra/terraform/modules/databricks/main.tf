# ---------------------------------------------------------------------------
# Azure Databricks, VNet-injected, with no public IPs.
#
# --- what VNet injection actually changes ----------------------------------
#
# A default Databricks workspace creates its clusters in a VNet that Databricks
# owns, in a resource group you cannot meaningfully control. Those clusters get
# public IPs and reach your data over the internet or over service endpoints.
#
# VNet injection puts the cluster VMs in YOUR VNet, in subnets you defined,
# behind NSGs and route tables you control. That is what makes it possible for
# a Databricks cluster to reach a private endpoint at all — and therefore what
# makes "no PaaS service has a public endpoint" achievable rather than
# aspirational.
#
# --- secure cluster connectivity (no_public_ip) -----------------------------
#
# With SCC enabled, cluster nodes have no public IP and no inbound port open.
# Instead the cluster opens an OUTBOUND connection to the Databricks control
# plane and holds it open — a reverse tunnel. The control plane sends
# instructions down that existing connection.
#
# The consequence people hit: the cluster now depends on outbound reachability
# to the Databricks control plane, so the hub firewall must allow
# *.azuredatabricks.net and the regional SCC relay. If it does not, clusters
# sit in PENDING for around 20 minutes and then fail with a message that does
# not mention the firewall. This is the single most common Databricks
# networking incident, and it is why those FQDNs are in the hub module's
# default allow-list.
#
# --- the two subnets --------------------------------------------------------
#
# Databricks requires exactly two delegated subnets and will not share them
# with anything else. Their sizing sets a hard ceiling on cluster size: each
# node consumes two IPs (one host, one container), so a /22 pair supports
# roughly 500 concurrent nodes. Resizing later requires recreating the
# workspace.
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

resource "azurerm_databricks_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  tags                = var.tags

  managed_resource_group_name = var.managed_resource_group_name

  # The workspace URL itself is reachable only through a private endpoint or
  # from an allow-listed network. Combined with SCC, neither the control plane
  # UI nor the data plane has a public surface.
  public_network_access_enabled = false

  # Databricks normally injects a large set of rules into the subnet NSGs.
  # "NoAzureDatabricksRules" tells it not to, because with private connectivity
  # the platform supplies its own. Changing this after creation is disruptive.
  network_security_group_rules_required = "NoAzureDatabricksRules"

  # Customer-managed keys for the managed disks of cluster nodes. Left off:
  # it requires a Key Vault key with purge protection and a specific grant
  # order, and enabling it later is non-disruptive. Documented rather than
  # silently omitted — see docs/architecture/06-data-platform.md.
  customer_managed_key_enabled = false

  custom_parameters {
    no_public_ip = true

    virtual_network_id                                   = var.virtual_network_id
    private_subnet_name                                  = var.host_subnet_name
    public_subnet_name                                   = var.container_subnet_name
    private_subnet_network_security_group_association_id = var.host_subnet_nsg_association_id
    public_subnet_network_security_group_association_id  = var.container_subnet_nsg_association_id
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- Unity Catalog access connector ----------------------------------------
#
# The bridge between Unity Catalog and the lakehouse storage.
#
# Before Unity Catalog, a cluster reached storage using either a service
# principal secret in a notebook, or a mount point created with credentials
# that every user of the workspace inherited. Both mean the storage
# permissions and the analytics permissions are separate systems that drift.
#
# The access connector is a managed identity that Unity Catalog assumes. The
# storage account grants Storage Blob Data Contributor to THIS identity and
# to nobody else; individual users are then granted access to tables and
# volumes inside Unity Catalog, and Unity Catalog brokers the storage access
# on their behalf. There is one place to grant, one place to audit, and no
# credential anywhere.
resource "azurerm_databricks_access_connector" "unity_catalog" {
  name                = "${var.name}-uc-connector"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "unity_catalog_storage" {
  scope                = var.lakehouse_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.unity_catalog.identity[0].principal_id
  principal_type       = "ServicePrincipal"

  description = "Unity Catalog brokers all lakehouse access through this identity. No human and no cluster holds storage credentials directly."
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_databricks_workspace.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Premium-tier audit logging. `notebook` and `unityCatalog` are the two that
  # answer governance questions: who ran what, and who read which table.
  enabled_log { category = "accounts" }
  enabled_log { category = "clusters" }
  enabled_log { category = "notebook" }
  enabled_log { category = "jobs" }
  enabled_log { category = "unityCatalog" }
  enabled_log { category = "secrets" }
  enabled_log { category = "workspace" }
}
