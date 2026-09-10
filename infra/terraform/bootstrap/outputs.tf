output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "The demo resource group (also used by the root config)."
}

output "state_storage_account_name" {
  value       = azurerm_storage_account.tfstate.name
  description = "Storage account backing the root module's remote state. Put this in ../backend.hcl."
}

output "state_container_name" {
  value       = azurerm_storage_container.tfstate.name
  description = "Blob container for tfstate. Put this in ../backend.hcl."
}

output "backend_hcl" {
  description = "Copy this block into ../backend.hcl (then `terraform init -backend-config=backend.hcl` in the root)."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.rg.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    key                  = "genie-demo.tfstate"
  EOT
}
