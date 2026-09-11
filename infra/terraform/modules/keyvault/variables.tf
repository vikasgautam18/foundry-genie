variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name_prefix" { type = string }
variable "name_suffix" {
  type    = string
  default = ""
}
variable "tags" { type = map(string) }
variable "tenant_id" { type = string }
variable "public_network_access" { type = bool }
variable "pe_subnet_id" { type = string }
variable "dns_zone_ids" { type = map(string) }

variable "deployer_object_id" {
  type        = string
  description = "Object ID of the principal running Terraform (granted Secrets Officer to write secrets)."
}

variable "allow_deployer_data_plane" {
  type        = bool
  description = "If true, keep KV reachable (public access + Allow ACL) so Terraform can write secrets from outside the VNet. Set false for a hardened, in-VNet-only provisioning runner."
  default     = true
}

variable "secret_names" {
  type        = list(string)
  description = "Names of secrets to create (non-sensitive; used for for_each keys)."
  default     = []
}

variable "secrets" {
  type        = map(string)
  description = "Secret name => value lookup (values may be sensitive)."
  default     = {}
  sensitive   = true
}
