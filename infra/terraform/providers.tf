provider "azurerm" {
  features {
    key_vault {
      # Demo convenience; set true if you want purge-on-destroy in throwaway envs.
      purge_soft_delete_on_destroy = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "random" {}

# The Databricks provider is configured from the workspace this config creates.
# Data-plane resources (e.g. the SQL warehouse) are gated behind
# var.create_databricks_sql_warehouse and may require the workspace to exist
# first (see README: two-step apply with -target=module.databricks).
provider "databricks" {
  host                        = module.databricks.workspace_url
  azure_workspace_resource_id = module.databricks.workspace_id
}
