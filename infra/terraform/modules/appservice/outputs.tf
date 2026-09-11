output "web_app_name" {
  value = var.create_web ? azurerm_linux_web_app.web[0].name : null
}

output "web_app_default_hostname" {
  value = var.create_web ? azurerm_linux_web_app.web[0].default_hostname : null
}

output "web_principal_id" {
  value = var.create_web ? azurerm_linux_web_app.web[0].identity[0].principal_id : null
}

output "teams_app_name" {
  value = var.create_teams ? azurerm_linux_web_app.teams[0].name : null
}

output "teams_app_default_hostname" {
  value = var.create_teams ? azurerm_linux_web_app.teams[0].default_hostname : null
}

output "teams_principal_id" {
  value = var.create_teams ? azurerm_linux_web_app.teams[0].identity[0].principal_id : null
}

output "app_principal_ids" {
  description = "Non-null app MI principal IDs (for RBAC assignments)."
  value = compact([
    var.create_web ? azurerm_linux_web_app.web[0].identity[0].principal_id : "",
    var.create_teams ? azurerm_linux_web_app.teams[0].identity[0].principal_id : "",
  ])
}
