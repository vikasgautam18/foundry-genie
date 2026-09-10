data "azurerm_subscription" "current" {}

locals {
  # "Foundry User" (formerly "Azure AI User"). Use the stable role GUID because
  # the display name is mid-rename. Grants data-plane agents/threads/runs.
  foundry_user_role_id = "${data.azurerm_subscription.current.id}/providers/Microsoft.Authorization/roleDefinitions/53ca6127-db72-4b80-b1b0-d745d6d5456d"
}

resource "azurerm_role_assignment" "acr_pull" {
  for_each             = var.app_principals
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  for_each             = var.app_principals
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "foundry_user_app" {
  for_each           = var.app_principals
  scope              = var.foundry_project_id
  role_definition_id = local.foundry_user_role_id
  principal_id       = each.value
}

# The Foundry project's own managed identity needs Foundry User on the account.
resource "azurerm_role_assignment" "foundry_user_project_mi" {
  count              = var.assign_project_mi ? 1 : 0
  scope              = var.foundry_account_id
  role_definition_id = local.foundry_user_role_id
  principal_id       = var.foundry_project_principal_id
}

# Redis data-plane authorization is an access-policy assignment (NOT Azure RBAC).
# "Data Contributor" covers GET/SET/GETDEL/DEL/EXISTS/SETEX used by the token store.
resource "azurerm_redis_cache_access_policy_assignment" "app" {
  for_each           = var.assign_redis ? var.app_principals : {}
  name               = "${each.key}-mi"
  redis_cache_id     = var.redis_id
  access_policy_name = "Data Contributor"
  object_id          = each.value
  object_id_alias    = "${each.key}-mi"
}
