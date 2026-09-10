output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

output "vnet_name" {
  value = azurerm_virtual_network.vnet.name
}

output "pe_subnet_id" {
  value = azurerm_subnet.pe.id
}

output "pe_subnet_name" {
  value = azurerm_subnet.pe.name
}

output "webapp_subnet_id" {
  value = azurerm_subnet.webapp.id
}

output "webapp_subnet_name" {
  value = azurerm_subnet.webapp.name
}

output "dbx_host_subnet_name" {
  value = azurerm_subnet.dbx_host.name
}

output "dbx_container_subnet_name" {
  value = azurerm_subnet.dbx_container.name
}

output "dbx_host_nsg_association_id" {
  value = azurerm_subnet_network_security_group_association.dbx_host.id
}

output "dbx_container_nsg_association_id" {
  value = azurerm_subnet_network_security_group_association.dbx_container.id
}

output "dns_zone_ids" {
  description = "Map of private DNS zone name => zone id (for private_dns_zone_group blocks)."
  value       = { for name, z in azurerm_private_dns_zone.zones : name => z.id }
}
