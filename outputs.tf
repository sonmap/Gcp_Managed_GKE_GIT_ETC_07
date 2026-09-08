output "edge_project_number" {
  value       = data.google_project.edge.number
  description = "Project number used in the GKE Workload Identity principal."
}

output "ksa_principal" {
  value       = local.ksa_principal
  description = "KSA federated principal granted access in the SBX-A project."
}

output "namespace" {
  value = kubernetes_namespace_v1.sbx.metadata[0].name
}

output "task_group_email" {
  value = var.task_group_email
}

output "bigquery_dataset" {
  value = "${var.sbx_project_id}:${google_bigquery_dataset.sbx.dataset_id}"
}

output "storage_bucket" {
  value = google_storage_bucket.sbx.url
}

