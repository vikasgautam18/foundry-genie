variable "subscription_id" {
  type        = string
  description = "Azure subscription ID. If null, the provider uses ARM_SUBSCRIPTION_ID / az login context."
  default     = null
}

variable "location" {
  type        = string
  description = "Azure region for the resource group and state storage."
  default     = "centralindia"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the (new) resource group that holds ALL demo resources."
  default     = "genie_demo_rg"
}

variable "state_sa_prefix" {
  type        = string
  description = "Prefix for the globally-unique tfstate storage account name (a random suffix is appended)."
  default     = "geniedemotfstate"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to bootstrap resources."
  default = {
    project = "foundry-genie"
    env     = "demo"
    managed = "terraform-bootstrap"
  }
}
