# ---------------------------------------------------------------------------
# Cosmos DB — the operational data store behind the API.
#
# Three decisions dominate a Cosmos design. Two of them are irreversible.
#
# --- 1. Partition key (IRREVERSIBLE) ---------------------------------------
#
# Cosmos shards data into physical partitions of at most 50 GB and 10,000 RU/s
# each. The partition key decides which logical partition a document lands in,
# and therefore whether load spreads or concentrates.
#
# A good partition key has high cardinality and even access. For a
# 1,000,000-user product, `/tenantId` looks natural and is usually wrong: the
# largest tenant becomes a hot partition that no amount of provisioned
# throughput can relieve, because a single logical partition is capped at
# 10,000 RU/s regardless of what the container is provisioned for. This is the
# "hot partition" failure, and it presents as 429s under a total load far
# below the provisioned ceiling.
#
# `/userId` gives a million logical partitions and near-perfect spread. The
# cost is that any query across users becomes cross-partition — a fan-out
# whose RU charge scales with the number of physical partitions. That is an
# acceptable trade when the read pattern is genuinely per-user, which for a
# per-user dataset product it is.
#
# Changing the key later means creating a new container and migrating every
# document. Choose it as if it were a schema you cannot alter, because it is.
#
# --- 2. Consistency level (reversible, but changes correctness) ------------
#
#   Strong            Linearizable. Reads never see stale data. Costs 2x RU on
#                     reads and FORBIDS multi-region writes. Latency is bounded
#                     by the slowest region.
#   BoundedStaleness  Lag bounded by K versions or T seconds. The compromise
#                     when "eventually" is not good enough but Strong is too
#                     expensive.
#   Session           DEFAULT HERE. Within one session token, a client always
#                     reads its own writes in order. Different users may briefly
#                     see different states — which for a per-user dataset
#                     product is invisible, because users only read their own
#                     data.
#   ConsistentPrefix  Never see out-of-order writes, but may see stale ones.
#   Eventual          Cheapest, weakest. Fine for a view counter, not for
#                     anything a user will notice being wrong.
#
# Session is chosen because the access pattern is per-user. If this platform
# added a cross-user feature — a shared workspace, a leaderboard — that feature
# would need BoundedStaleness or its own consistency story. The consistency
# level is a property of the ACCESS PATTERN, not of the database.
#
# --- 3. Throughput model (reversible) --------------------------------------
#
# Autoscale is used throughout. It bills at 1.5x the rate of manual
# provisioning for the same ceiling, but scales between 10% and 100% of that
# ceiling automatically. For a workload with a diurnal curve — which a
# consumer product always has — autoscale is cheaper in practice than manual
# provisioning sized for peak, and it removes an entire class of 3am page.
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
  # Strong consistency and multi-region writes are mutually exclusive in
  # Cosmos: you cannot have linearizable reads across regions that both accept
  # writes. Catching this in Terraform gives a clear message instead of an
  # opaque ARM error twenty minutes into an apply.
  consistency_conflicts_with_multiwrite = (
    var.consistency_level == "Strong" && var.enable_multi_region_writes
  )

  # Serverless accounts cannot have secondary regions or autoscale.
  serverless_conflicts = var.enable_serverless && length(var.secondary_locations) > 0
}

resource "azurerm_cosmosdb_account" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  offer_type = "Standard"

  # Blocks writes to key metadata through the management plane. Local auth is
  # already off below, but this closes the adjacent path: someone holding
  # Contributor on the resource — and no data-plane role — could otherwise
  # regenerate a key through ARM.
  access_key_metadata_writes_enabled = false
  kind                               = "GlobalDocumentDB" # the SQL / NoSQL API

  automatic_failover_enabled       = true
  multiple_write_locations_enabled = var.enable_multi_region_writes

  # Entra-only authentication. Cosmos account keys are the same problem as
  # storage account keys: unscoped, unattributable, and permanently valid.
  # Disabling them forces every caller through Cosmos data-plane RBAC.
  local_authentication_enabled = false

  public_network_access_enabled     = false
  is_virtual_network_filter_enabled = true

  consistency_policy {
    consistency_level = var.consistency_level

    # Only read when consistency_level is BoundedStaleness, but the provider
    # requires them to be present and in valid ranges regardless.
    max_interval_in_seconds = 300
    max_staleness_prefix    = 100000
  }

  # Failover priority 0 is the write region. The order of the remaining
  # entries is the order Azure promotes them in a regional outage, so it is a
  # deliberate ranking, not an arbitrary list.
  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = var.zone_redundant
  }

  dynamic "geo_location" {
    for_each = var.secondary_locations
    content {
      location          = geo_location.value
      failover_priority = geo_location.key + 1
      zone_redundant    = var.zone_redundant
    }
  }

  dynamic "capabilities" {
    for_each = var.enable_serverless ? ["EnableServerless"] : []
    content {
      name = capabilities.value
    }
  }

  backup {
    type = "Continuous"
    tier = var.backup_tier
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = !local.consistency_conflicts_with_multiwrite
      error_message = "Strong consistency cannot be combined with multi-region writes. Choose BoundedStaleness if you need both bounded staleness and write availability in every region."
    }

    precondition {
      condition     = !local.serverless_conflicts
      error_message = "A serverless Cosmos account cannot have secondary regions. Set enable_serverless = false, or clear secondary_locations."
    }
  }
}

resource "azurerm_cosmosdb_sql_database" "this" {
  name                = var.database_name
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name

  # No throughput is set here, deliberately. Throughput can be provisioned on
  # the DATABASE (shared by every container in it) or on each CONTAINER.
  # Shared throughput sounds efficient and is a trap: containers compete for
  # one RU budget, so a single noisy container starves the rest, and the
  # per-container metrics that would tell you which one do not exist. Every
  # container below provisions its own.
}

resource "azurerm_cosmosdb_sql_container" "this" {
  for_each = var.containers

  name                = each.key
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  database_name       = azurerm_cosmosdb_sql_database.this.name

  partition_key_paths = [each.value.partition_key_path]

  # Version 2 supports partition key values larger than 100 bytes. There is no
  # reason to choose version 1 in a new design.
  partition_key_version = 2

  # -1 means "TTL is enabled on the container but off by default per item", so
  # individual documents can opt in with a `ttl` field. A positive value
  # expires every document. Setting it to null disables TTL entirely, which
  # means a session or cache container grows forever.
  default_ttl = each.value.default_ttl_seconds

  dynamic "autoscale_settings" {
    for_each = var.enable_serverless ? [] : [1]
    content {
      max_throughput = each.value.max_throughput
    }
  }

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/*"
    }

    # Cosmos indexes every property by default, and indexing is charged on
    # WRITE. A document with a large unqueried payload — a raw JSON blob, an
    # embedding vector, an audit trail — can easily double its own write cost
    # through indexing that nothing ever reads. Excluding those paths is the
    # cheapest RU optimisation available.
    dynamic "excluded_path" {
      for_each = each.value.excluded_index_paths
      content {
        path = excluded_path.value
      }
    }

    excluded_path {
      path = "/\"_etag\"/?"
    }
  }

  # Uniqueness is enforced WITHIN a logical partition only. A unique key on
  # /email in a container partitioned by /userId does not make email unique
  # across the database — a fact that has caused real production duplicates.
  dynamic "unique_key" {
    for_each = length(each.value.unique_key_paths) > 0 ? [1] : []
    content {
      paths = each.value.unique_key_paths
    }
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
    private_connection_resource_id = azurerm_cosmosdb_account.this.id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.private_dns_zone_ids
  }
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name                           = "to-log-analytics"
  target_resource_id             = azurerm_cosmosdb_account.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  # DataPlaneRequests is the expensive one and the useful one: it carries the
  # RU charge and status code of every request, which is how a 429 storm gets
  # attributed to a specific partition key value. Consider sampling it in a
  # high-volume production account.
  enabled_log { category = "DataPlaneRequests" }
  enabled_log { category = "QueryRuntimeStatistics" }
  enabled_log { category = "PartitionKeyStatistics" }
  enabled_log { category = "PartitionKeyRUConsumption" }
  enabled_log { category = "ControlPlaneRequests" }

  enabled_metric { category = "Requests" }
}
