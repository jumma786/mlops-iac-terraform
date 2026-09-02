terraform {
  # 1.9 is the floor for cross-variable references in `validation` blocks,
  # which variables.tf uses to reject unsupported cpu/memory pairs at plan time.
  required_version = ">= 1.9.0"

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

  # Remote state, supplied as a partial configuration so the storage account is
  # not hardcoded and the same files serve local work, CI and offline linting:
  #
  #   local  terraform init -backend-config=backend.hcl   (copy backend.hcl.example)
  #   CI     terraform init -backend-config="..." ...      (see the workflow)
  #   lint   terraform init -backend=false                 (no credentials needed)
  #
  # State has to be remote for CI to mean anything: a runner's local state is
  # discarded when the job ends, so every run would plan from empty and try to
  # recreate a stack that already exists.
  backend "azurerm" {
    # Authenticate to the state container with Azure AD rather than a storage
    # account key, so there is still no long-lived secret anywhere in the flow.
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {
    resource_group {
      # Refuse to delete a resource group that still contains resources.
      prevent_deletion_if_contains_resources = true
    }
  }
}
