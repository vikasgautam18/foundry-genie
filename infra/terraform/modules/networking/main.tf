locals {
  # Private DNS zones for every private endpoint in this architecture.
  # NOTE: privatelink.openai.azure.com is included here to fix the gap in the
  # original setup-networking.sh (AIServices accounts emit an openai.azure.com
  # CNAME for model inference).
  base_dns_zones = [
    "privatelink.azuredatabricks.net",
    "privatelink.cognitiveservices.azure.com",
    "privatelink.services.ai.azure.com",
    "privatelink.openai.azure.com",
    "privatelink.redis.cache.windows.net",
    "privatelink.vaultcore.azure.net",
  ]

  # ACR zones are only created when ACR is private (omitted for acr_public_pull,
  # otherwise the linked-but-empty zone would NXDOMAIN the public ACR name).
  acr_dns_zones = var.include_acr_dns ? [
    "privatelink.azurecr.io",
    "${var.location}.data.privatelink.azurecr.io",
  ] : []

  private_dns_zones = concat(local.base_dns_zones, local.acr_dns_zones)
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.name_prefix}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "pe" {
  name                              = "private-endpoints-subnet"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.vnet.name
  address_prefixes                  = [var.pe_subnet_prefix]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "webapp" {
  name                 = "webapp-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.webapp_subnet_prefix]

  delegation {
    name = "webapp-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# ── NSG (mirrors infra/setup-networking.sh, tightened to this VNet) ─────────
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.name_prefix}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "allow-azure-dns"
    priority                   = 101
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefixes    = [var.webapp_subnet_prefix, var.pe_subnet_prefix]
    destination_address_prefix = "168.63.129.16"
  }

  security_rule {
    name                       = "allow-databricks-https"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.pe_subnet_prefix
    destination_address_prefix = "AzureDatabricks"
  }

  security_rule {
    name                       = "allow-acr-https"
    priority                   = 115
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.webapp_subnet_prefix
    destination_address_prefix = "AzureContainerRegistry"
  }

  security_rule {
    name                       = "allow-webapp-to-pe-subnet"
    priority                   = 105
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.webapp_subnet_prefix
    destination_address_prefix = var.pe_subnet_prefix
  }

  security_rule {
    name                       = "allow-foundry-https"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.webapp_subnet_prefix
    destination_address_prefix = "CognitiveServicesManagement"
  }

  security_rule {
    name                       = "allow-botservice-https"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.webapp_subnet_prefix
    destination_address_prefix = "AzureCloud"
  }

  security_rule {
    name                       = "allow-azuread-https"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.webapp_subnet_prefix
    destination_address_prefix = "AzureActiveDirectory"
  }

  security_rule {
    name                       = "deny-all-outbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.pe.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_subnet_network_security_group_association" "webapp" {
  subnet_id                 = azurerm_subnet.webapp.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# ── Databricks VNet injection subnets (host/public + container/private) ────
resource "azurerm_network_security_group" "dbx" {
  name                = "${var.name_prefix}-dbx-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet" "dbx_host" {
  name                 = "dbx-host-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.dbx_host_subnet_prefix]

  delegation {
    name = "databricks-delegation"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet" "dbx_container" {
  name                 = "dbx-container-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.dbx_container_subnet_prefix]

  delegation {
    name = "databricks-delegation"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "dbx_host" {
  subnet_id                 = azurerm_subnet.dbx_host.id
  network_security_group_id = azurerm_network_security_group.dbx.id
}

resource "azurerm_subnet_network_security_group_association" "dbx_container" {
  subnet_id                 = azurerm_subnet.dbx_container.id
  network_security_group_id = azurerm_network_security_group.dbx.id
}

# ── Private DNS zones + VNet links ─────────────────────────────────────────
resource "azurerm_private_dns_zone" "zones" {
  for_each            = toset(local.private_dns_zones)
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each              = azurerm_private_dns_zone.zones
  name                  = "${replace(each.value.name, ".", "-")}-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = var.tags
}
