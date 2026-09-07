terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {
    key = "dev/platform.tfstate"
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    key_vault {
      # The opposite of production, on purpose. Dev is torn down and rebuilt
      # constantly; without purging on destroy, the vault NAME stays reserved
      # for the soft-delete retention period and the next `terraform apply`
      # fails with "vault name already in use" — pointing at a vault that no
      # longer appears in the portal.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }
}
