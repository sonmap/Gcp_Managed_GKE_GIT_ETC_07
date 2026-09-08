locals {
  ksa_principal = "principal://iam.googleapis.com/projects/${data.google_project.edge.number}/locations/global/workloadIdentityPools/${var.edge_project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.ksa_name}"

  common_labels = {
    environment = "sandbox"
    tenant      = replace(var.namespace, "_", "-")
    managed-by  = "terraform"
  }
}

