resource "google_bigquery_dataset" "sbx" {
  provider = google.sbx

  project                    = var.sbx_project_id
  dataset_id                 = var.bigquery_dataset_id
  friendly_name              = "${upper(var.namespace)} analysis dataset"
  description                = "Dataset dedicated to ${var.namespace} notebook workloads."
  location                   = var.bigquery_location
  delete_contents_on_destroy = false
  labels                     = local.common_labels
}

resource "google_storage_bucket" "sbx" {
  provider = google.sbx

  project                     = var.sbx_project_id
  name                        = var.storage_bucket_name
  location                    = var.storage_location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.common_labels

  versioning {
    enabled = true
  }
}

