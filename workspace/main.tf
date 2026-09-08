resource "googleworkspace_group" "task" {
  email       = var.task_group_email
  name        = var.task_group_name
  description = "Users authorized for the SBX-A Jupyter environment. Managed by Terraform."
}

resource "googleworkspace_group_member" "admin_owner" {
  group_id         = googleworkspace_group.task.id
  email            = var.impersonated_user_email
  role             = "OWNER"
  type             = "USER"
  delivery_settings = "NONE"
}

resource "googleworkspace_group_member" "users" {
  for_each = var.users

  group_id         = googleworkspace_group.task.id
  email            = each.value
  role             = "MEMBER"
  type             = "USER"
  delivery_settings = "NONE"
}

resource "googleworkspace_group" "gke_security" {
  count = var.create_gke_security_group ? 1 : 0

  email       = var.gke_security_group_email
  name        = "GKE Security Groups"
  description = "Required parent group for GKE Google Groups RBAC. Managed by Terraform."
}

resource "googleworkspace_group_member" "task_group_in_gke_security" {
  count = var.create_gke_security_group ? 1 : 0

  group_id         = googleworkspace_group.gke_security[0].id
  email            = googleworkspace_group.task.email
  role             = "MEMBER"
  type             = "GROUP"
  delivery_settings = "NONE"
}

output "task_group_email" {
  value = googleworkspace_group.task.email
}

output "task_group_id" {
  value = googleworkspace_group.task.id
}

