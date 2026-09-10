locals {
  # For full-private KV, data-plane writes from an external Terraform runner
  # require reachability. allow_deployer_data_plane keeps the vault open enough
  # to write secrets; the private endpoint is still created for in-VNet clients.
  kv_public_access = var.allow_deployer_data_plane ? true : var.public_network_access
  kv_default_acl   = var.allow_deployer_data_plane ? "Allow" : "Deny"
}

resource "azurerm_key_vault" "kv" {
  name                          = "${var.name_prefix}-kv-${var.name_suffix}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = local.kv_public_access
  tags                          = var.tags

  network_acls {
    default_action = local.kv_default_acl
    bypass         = "AzureServices"
  }
}

# Let the Terraform principal create secrets (RBAC data-plane).
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.deployer_object_id
}

resource "azurerm_key_vault_secret" "secrets" {
  for_each     = toset(var.secret_names)
  name         = each.value
  value        = var.secrets[each.value]
  key_vault_id = azurerm_key_vault.kv.id

  # Role propagation can lag; if the first apply fails writing secrets, re-run.
  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

resource "azurerm_private_endpoint" "kv" {
  count               = var.public_network_access ? 0 : 1
  name                = "${var.name_prefix}-kv-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "kv-connection"
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv-dns-group"
    private_dns_zone_ids = compact([lookup(var.dns_zone_ids, "privatelink.vaultcore.azure.net", null)])
  }
}
