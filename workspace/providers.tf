provider "googleworkspace" {
  credentials             = var.credentials_file
  customer_id             = var.customer_id
  impersonated_user_email = var.impersonated_user_email
  oauth_scopes = [
    "https://www.googleapis.com/auth/admin.directory.group",
    "https://www.googleapis.com/auth/admin.directory.group.member",
  ]
}

