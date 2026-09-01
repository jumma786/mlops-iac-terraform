terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state. Commented out so `terraform init` works locally on a first run.
  # Create the storage account once (see README), then uncomment and re-init:
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstate<unique>"
  #   container_name       = "tfstate"
  #   key                  = "mlops-iac.tfstate"
  # }
}

provider "azurerm" {
  features {
    resource_group {
      # Refuse to delete a resource group that still contains resources.
      prevent_deletion_if_contains_resources = true
    }
  }
}
