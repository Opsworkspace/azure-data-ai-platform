# ---------------------------------------------------------------------------
# Bootstrap: the remote state backend.
#
# This configuration uses LOCAL state, on purpose. See README.md in this
# directory for the reasoning.
#
# It is the only Terraform in this repository with no backend block.
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

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      # Refuse to delete a resource group that still contains resources.
      # The default (true) will happily delete resources Terraform does not
      # know about, which in a shared subscription is how someone else's work
      # disappears.
      prevent_deletion_if_contains_resources = true
    }
  }
}

resource "azurerm_resource_group" "state" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    purpose     = "terraform-state"
    managed_by  = "terraform"
    environment = "shared"
    owner       = var.owner
    # Deleting this resource group orphans the state for every environment.
    criticality = "platform-critical"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_account" "state" {
  name                = var.storage_account_name
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location

  account_tier             = "Standard"
  account_kind             = "StorageV2"
  account_replication_type = "GZRS"

  # Not a data lake. State is a small number of small blobs; a hierarchical
  # namespace adds nothing and complicates the blob leasing Terraform relies
  # on for state locking.
  is_hns_enabled = false

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # Entra identity only. A state file contains every resource attribute in
  # plaintext, including values marked `sensitive` in the configuration.
  # A shared key that grants read access to it is a credential that grants
  # read access to every secret the platform has ever generated.
  shared_access_key_enabled       = false
  local_user_enabled              = false
  default_to_oauth_authentication = true

  # Public access is left enabled here and ONLY here. A private endpoint on
  # the state account creates a second chicken-and-egg problem: the network
  # that hosts the private endpoint is itself created by Terraform that needs
  # this backend. In a funded environment the resolution is a self-hosted CI
  # runner inside the VNet, after which this becomes false.
  public_network_access_enabled = true

  # Public access being ON does not mean open to the internet. The default
  # action for an account with no network rules is Allow, which is what makes
  # "public access enabled" actually mean "reachable from anywhere" — and a
  # state file is the single highest-value blob in the platform: it contains
  # every resource attribute in plaintext, including values marked sensitive.
  #
  # Deny by default, with an explicit allowlist. `state_allowed_ip_ranges`
  # defaults to empty, so an operator who has not set it is locked out rather
  # than silently exposed. That is the correct direction to fail.
  #
  # bypass = AzureServices keeps the portal's blob browser and Azure-internal
  # callers working; it does not open the account to the internet.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = var.state_allowed_ip_ranges
  }

  blob_properties {
    # The recovery path for a corrupted state write. Terraform writes state as
    # a whole-blob PUT; an interrupted apply can leave it truncated, and
    # versioning is what turns that from a rebuild into a one-minute restore.
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# State locking uses native blob leases and needs no extra infrastructure —
# unlike the AWS equivalent, which requires a DynamoDB table. Terraform takes
# an exclusive lease on the state blob for the duration of an operation; a
# second concurrent apply blocks with "Error acquiring the state lock" rather
# than interleaving writes and corrupting state.
#
# If a run is killed mid-apply the lease can be left held. `terraform force-unlock <ID>`
# releases it — after confirming no apply is genuinely still running, because
# breaking a live lease is how state gets corrupted for real.
