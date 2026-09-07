terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state.
  #
  # Intentionally partial. The storage account and resource group names are
  # tenancy-identifying, so they are supplied at init time from a gitignored
  # file rather than committed:
  #
  #     terraform init -backend-config=../../backend.hcl
  #
  # `use_azuread_auth = true` in that file is what makes this work against a
  # storage account with shared keys disabled. Without it, Terraform tries to
  # authenticate with an account key that does not exist and fails with a
  # message about the key, not about authentication mode.
  # ---------------------------------------------------------------------------
  backend "azurerm" {
    key = "stage/platform.tfstate"
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }

    key_vault {
      # In production, a deleted vault should stay recoverable for its full
      # retention period. Purging on destroy would defeat soft delete.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }

    log_analytics_workspace {
      permanently_delete_on_destroy = false
    }
  }
}
