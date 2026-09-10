locals {
  acr_public = var.public_network_access || var.public_pull
}

# Premium SKU is required for private endpoints.
resource "azurerm_container_registry" "acr" {
  name                          = "${var.name_prefix}acr${var.name_suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = local.acr_public
  tags                          = var.tags

  # When public-only (acr_public_pull), the registry firewall must allow public
  # access; otherwise the MI image pull fails with ACRTokenRetrievalFailure.
  dynamic "network_rule_set" {
    for_each = var.public_pull ? [1] : []
    content {
      default_action = "Allow"
    }
  }
}

resource "azurerm_private_endpoint" "acr" {
  count               = local.acr_public ? 0 : 1
  name                = "${var.name_prefix}-acr-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "acr-connection"
    private_connection_resource_id = azurerm_container_registry.acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "acr-dns-group"
    private_dns_zone_ids = compact([
      lookup(var.dns_zone_ids, "privatelink.azurecr.io", null),
      lookup(var.dns_zone_ids, "${var.location}.data.privatelink.azurecr.io", null),
    ])
  }
}
