# ---------------------------------------------------------------------------
# The lakehouse: ADLS Gen2 storage, organised as a medallion architecture.
#
# ADLS Gen2 is not a separate product. It is a storage account with
# `is_hns_enabled = true` — a hierarchical namespace. That one flag turns a
# flat key-value blob store into something with real directories, which means
# atomic directory rename, POSIX-style ACLs, and directory-level operations
# that do not cost one API call per object. Delta Lake's transaction protocol
# depends on atomic rename; running Delta on a flat blob account works but
# loses that guarantee under concurrent writers.
#
# The flag cannot be changed after creation. Getting it wrong means migrating
# every byte.
#
# Bronze / silver / gold:
#   bronze  raw, immutable, exactly as received. Never edited, only appended.
#   silver  cleaned, conformed, deduplicated, schema-enforced.
#   gold    aggregated, business-shaped, what dashboards and the API read.
#
# Why the separation earns its keep: when a downstream number is wrong, you
# can re-derive silver and gold from bronze without re-ingesting from the
# source system. Without a bronze layer, a bad transform is unrecoverable.
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

resource "azurerm_storage_account" "lakehouse" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.replication_type

  # The flag that makes this a data lake rather than a blob store.
  is_hns_enabled = true

  # --- identity-based access only ------------------------------------------
  # Shared keys are the storage equivalent of a root password: they cannot be
  # scoped, cannot be attributed to a person, and appear in every connection
  # string that gets pasted into a notebook. Disabling them forces every
  # caller onto Entra identity, which is auditable and revocable.
  #
  # This has a real consequence: any tool that only speaks connection strings
  # stops working. That is the intended outcome.
  shared_access_key_enabled = false

  # No anonymous container access, ever.
  allow_nested_items_to_be_public = false

  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  public_network_access_enabled = false

  # Entra-authenticated access to the file/blob endpoints.
  default_to_oauth_authentication = true

  network_rules {
    default_action = "Deny"
    # Trusted Microsoft services bypass covers Databricks Unity Catalog's
    # managed identity path and Azure Monitor's export. Without it, Unity
    # Catalog cannot reach an external location behind a private endpoint.
    bypass = ["AzureServices"]
  }

  blob_properties {
    # Versioning plus change feed is what makes an accidental overwrite
    # recoverable and an audit reconstructable.
    versioning_enabled       = true
    change_feed_enabled      = true
    last_access_time_enabled = true

    delete_retention_policy {
      days = var.delete_retention_days
    }

    container_delete_retention_policy {
      days = var.delete_retention_days
    }
  }

  lifecycle {
    # is_hns_enabled and account_kind force replacement, which on a lakehouse
    # means destroying every byte of data. Terraform should never be able to
    # do that as a side effect of an unrelated change.
    prevent_destroy = true
  }
}

# --- medallion filesystems --------------------------------------------------

resource "azurerm_storage_container" "medallion" {
  for_each = toset(var.medallion_containers)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.lakehouse.id
  container_access_type = "private"
}

# --- private endpoints ------------------------------------------------------
# Two endpoints, not one. A Gen2 account exposes blob and dfs as separate
# sub-resources on separate hostnames. Creating only the blob endpoint gives a
# lakehouse where `spark.read.parquet("abfss://...")` times out while the
# Azure CLI works, and the difference is invisible in the portal.

resource "azurerm_private_endpoint" "blob" {
  name                = "${var.name}-blob-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name}-blob-psc"
    private_connection_resource_id = azurerm_storage_account.lakehouse.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.blob_private_dns_zone_ids
  }
}

resource "azurerm_private_endpoint" "dfs" {
  name                = "${var.name}-dfs-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name}-dfs-psc"
    private_connection_resource_id = azurerm_storage_account.lakehouse.id
    subresource_names              = ["dfs"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.dfs_private_dns_zone_ids
  }
}

# --- lifecycle management ---------------------------------------------------
# Bronze grows without bound by design — it is never deleted, only aged. This
# policy is what stops "never deleted" from meaning "always billed at hot
# tier rates". Silver and gold are left on hot: they are read constantly, and
# early-deletion penalties on cool storage make tiering them a false economy.

resource "azurerm_storage_management_policy" "lakehouse" {
  count = var.enable_lifecycle_management ? 1 : 0

  storage_account_id = azurerm_storage_account.lakehouse.id

  rule {
    name    = "bronze-tiering"
    enabled = true

    filters {
      prefix_match = ["bronze/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        # Cool after 30 days: cheaper storage, higher read cost, 30-day
        # minimum retention before early-deletion charges apply.
        tier_to_cool_after_days_since_modification_greater_than = 30
        # Cold after 90: cheaper again, 90-day minimum.
        tier_to_cold_after_days_since_modification_greater_than = 90
        # Archive after a year. Archive has a REHYDRATION latency measured in
        # hours, so anything a support engineer might need at 03:00 must not
        # be here. Raw ingest older than a year qualifies.
        tier_to_archive_after_days_since_modification_greater_than = 365
      }

      # Old versions accumulate silently and are the usual reason a storage
      # bill grows without the data growing.
      version {
        delete_after_days_since_creation = 90
      }

      snapshot {
        delete_after_days_since_creation_greater_than = 90
      }
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "blob" {
  count = var.log_analytics_workspace_id != "" ? 1 : 0

  name = "to-log-analytics"
  # Diagnostics attach to the blob service, not the account: the account-level
  # resource only emits Transaction metrics, and the read/write/delete logs
  # people actually want live one level down.
  target_resource_id         = "${azurerm_storage_account.lakehouse.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "StorageRead" }
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }

  enabled_metric { category = "Transaction" }
}
