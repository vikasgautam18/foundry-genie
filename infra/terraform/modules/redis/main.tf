resource "azurerm_redis_cache" "redis" {
  name                          = "${var.name_prefix}-redis-${var.name_suffix}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  capacity                      = var.capacity
  family                        = var.family
  sku_name                      = var.sku_name
  minimum_tls_version           = "1.2"
  public_network_access_enabled = var.public_network_access
  tags                          = var.tags

  redis_configuration {
    # This tenant's policy disables access-key auth and enables Entra (AAD) auth
    # on Redis. Declare it so Terraform matches reality (else it tries to null it,
    # which fails: "Disabling both access key and Entra auth is not supported").
    active_directory_authentication_enabled = true
  }
}

resource "azurerm_private_endpoint" "redis" {
  count               = var.public_network_access ? 0 : 1
  name                = "${var.name_prefix}-redis-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "redis-connection"
    private_connection_resource_id = azurerm_redis_cache.redis.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis-dns-group"
    private_dns_zone_ids = compact([lookup(var.dns_zone_ids, "privatelink.redis.cache.windows.net", null)])
  }
}
