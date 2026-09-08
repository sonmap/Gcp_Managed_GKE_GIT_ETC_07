# Project-level permission to create BigQuery jobs. Data access is scoped to the dataset below.
resource "google_project_iam_member" "ksa_bigquery_job_user" {
  provider = google.sbx

  project = var.sbx_project_id
  role    = "roles/bigquery.jobUser"
  member  = local.ksa_principal
}

resource "google_bigquery_dataset_iam_member" "ksa_data_editor" {
  provider = google.sbx

  project    = var.sbx_project_id
  dataset_id = google_bigquery_dataset.sbx.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = local.ksa_principal
}

resource "google_storage_bucket_iam_member" "ksa_object_user" {
  provider = google.sbx

  bucket = google_storage_bucket.sbx.name
  role   = "roles/storage.objectUser"
  member = local.ksa_principal
}

