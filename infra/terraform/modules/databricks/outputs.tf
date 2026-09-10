output "workspace_id" {
  value = azurerm_databricks_workspace.this.id
}

output "workspace_name" {
  value = azurerm_databricks_workspace.this.name
}

output "workspace_host" {
  description = "Bare workspace hostname for DATABRICKS_HOST (no scheme)."
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "workspace_url" {
  description = "https:// workspace URL for the databricks provider host."
  value       = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "sql_warehouse_id" {
  value = var.create_sql_warehouse ? databricks_sql_endpoint.genie[0].id : null
}
