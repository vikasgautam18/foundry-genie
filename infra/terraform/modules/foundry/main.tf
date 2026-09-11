locals {
  # Globally-unique, DNS-safe subdomain that drives PROJECT_ENDPOINT host.
  subdomain    = "${var.name_prefix}foundry${var.name_suffix}"
  project_name = "${var.name_prefix}-proj"
}

# ── Azure AI Foundry account (kind: AIServices) ────────────────────────────
# Uses azapi because allowProjectManagement + the accounts/projects child and
# the AgentsClient project-endpoint model are newer than azurerm coverage.
resource "azapi_resource" "account" {
  type                      = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  name                      = "${var.name_prefix}-foundry-${var.name_suffix}"
  parent_id                 = var.resource_group_id
  location                  = var.account_location
  tags                      = var.tags
  schema_validation_enabled = false

  identity {
    type = "SystemAssigned"
  }

  # AIServices projects/accounts occasionally return a transient
  # 412 IfMatchPreconditionFailed (stale ETag) on update/delete — retry it.
  retry = {
    error_message_regex  = ["IfMatchPreconditionFailed", "PreconditionFailed", "TooManyRequests", "Conflict"]
    interval_seconds     = 15
    max_interval_seconds = 120
  }

  body = {
    kind = "AIServices"
    sku  = { name = "S0" }
    properties = {
      customSubDomainName    = local.subdomain
      allowProjectManagement = true
      publicNetworkAccess    = var.public_network_access ? "Enabled" : "Disabled"
    }
  }

  response_export_values = ["identity.principalId", "properties.endpoint"]
}

# ── Foundry project (child of the account) ─────────────────────────────────
resource "azapi_resource" "project" {
  type                      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name                      = local.project_name
  parent_id                 = azapi_resource.account.id
  location                  = var.account_location
  tags                      = var.tags
  schema_validation_enabled = false

  identity {
    type = "SystemAssigned"
  }

  retry = {
    error_message_regex  = ["IfMatchPreconditionFailed", "PreconditionFailed", "TooManyRequests", "Conflict"]
    interval_seconds     = 15
    max_interval_seconds = 120
  }

  body = {
    properties = {
      displayName = local.project_name
      description = "Foundry Genie market-campaign agent project"
    }
  }

  response_export_values = ["identity.principalId"]
}

# ── Model deployment ───────────────────────────────────────────────────────
resource "azapi_resource" "model" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2024-10-01"
  name      = var.model_deployment_name
  parent_id = azapi_resource.account.id

  body = {
    sku = {
      name     = var.model_sku
      capacity = var.model_capacity
    }
    properties = {
      model = {
        format  = "OpenAI"
        name    = var.model_name
        version = var.model_version
      }
    }
  }
}

# ── Private endpoint for the account (group-id: account) ───────────────────
resource "azurerm_private_endpoint" "foundry" {
  count               = var.public_network_access ? 0 : 1
  name                = "${var.name_prefix}-foundry-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "foundry-connection"
    private_connection_resource_id = azapi_resource.account.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "foundry-dns-group"
    private_dns_zone_ids = compact([
      lookup(var.dns_zone_ids, "privatelink.cognitiveservices.azure.com", null),
      lookup(var.dns_zone_ids, "privatelink.services.ai.azure.com", null),
      lookup(var.dns_zone_ids, "privatelink.openai.azure.com", null),
    ])
  }
}
