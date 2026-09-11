resource "azurerm_databricks_workspace" "this" {
  name                          = "${var.name_prefix}-dbx"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = var.sku
  public_network_access_enabled = var.workspace_public_network_access

  # Required when front-ending the workspace with Private Link (no public access).
  network_security_group_rules_required = var.public_network_access ? null : "NoAzureDatabricksRules"

  # VNet injection: mandatory for a public-access-disabled (private) workspace.
  custom_parameters {
    virtual_network_id                                   = var.virtual_network_id
    public_subnet_name                                   = var.public_subnet_name
    private_subnet_name                                  = var.private_subnet_name
    public_subnet_network_security_group_association_id  = var.public_subnet_nsg_association_id
    private_subnet_network_security_group_association_id = var.private_subnet_nsg_association_id
    no_public_ip                                         = true
  }

  tags = var.tags
}

# Front-end / REST API private endpoint (primary).
resource "azurerm_private_endpoint" "ui_api" {
  count               = var.public_network_access ? 0 : 1
  name                = "${var.name_prefix}-dbx-uiapi-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "databricks-uiapi-connection"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "databricks-dns-group"
    private_dns_zone_ids = compact([lookup(var.dns_zone_ids, "privatelink.azuredatabricks.net", null)])
  }
}

# Browser-authentication private endpoint (needed for U2M browser sign-in over Private Link).
resource "azurerm_private_endpoint" "browser_auth" {
  count               = var.public_network_access ? 0 : 1
  name                = "${var.name_prefix}-dbx-browser-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "databricks-browser-connection"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    subresource_names              = ["browser_authentication"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "databricks-browser-dns-group"
    private_dns_zone_ids = compact([lookup(var.dns_zone_ids, "privatelink.azuredatabricks.net", null)])
  }
}

# ── Optional: Pro SQL warehouse (Genie requires Pro/Serverless) ────────────
# Uses the databricks provider (configured at root from this workspace).
# If the first plan errors that the provider config is unknown, apply the
# workspace first:  terraform apply -target=module.databricks.azurerm_databricks_workspace.this
resource "databricks_sql_endpoint" "genie" {
  count            = var.create_sql_warehouse ? 1 : 0
  name             = "${var.name_prefix}-genie-wh"
  cluster_size     = "2X-Small"
  auto_stop_mins   = 10
  max_num_clusters = 1
  warehouse_type   = "PRO"

  depends_on = [azurerm_databricks_workspace.this]
}
