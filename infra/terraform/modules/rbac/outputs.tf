output "acr_pull_assignment_ids" {
  value = { for k, r in azurerm_role_assignment.acr_pull : k => r.id }
}

output "foundry_user_assignment_ids" {
  value = { for k, r in azurerm_role_assignment.foundry_user_app : k => r.id }
}
