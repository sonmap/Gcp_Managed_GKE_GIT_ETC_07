variable "credentials_file" {
  description = "Path to the Domain-Wide Delegation service-account JSON key. Prefer GOOGLEWORKSPACE_CREDENTIALS instead of committing a path."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true
}

variable "customer_id" {
  description = "Google Workspace customer ID from Admin Console."
  type        = string
}

variable "impersonated_user_email" {
  description = "Workspace administrator impersonated by Terraform."
  type        = string
  default     = "admin@sonmap.net"
}

variable "domain" {
  type    = string
  default = "sonmap.net"
}

variable "task_group_email" {
  type    = string
  default = "grp-sbx-a@sonmap.net"
}

variable "task_group_name" {
  type    = string
  default = "SBX-A Analysis Users"
}

variable "gke_security_group_email" {
  description = "Required parent group name for Google Groups for GKE RBAC."
  type        = string
  default     = "gke-security-groups@sonmap.net"
}

variable "create_gke_security_group" {
  description = "Set false when gke-security-groups already exists; import or manage the nesting separately."
  type        = bool
  default     = true
}

variable "users" {
  description = "Exactly five existing Google Workspace user emails."
  type        = set(string)

  validation {
    condition     = length(var.users) == 5
    error_message = "Exactly five users must be supplied."
  }

  validation {
    condition     = alltrue([for email in var.users : endswith(lower(email), "@${lower(var.domain)}")])
    error_message = "Every user must belong to the configured Workspace domain."
  }
}

