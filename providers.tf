provider "google" {
  project = var.edge_project_id
  region  = var.region
}

provider "google" {
  alias   = "sbx"
  project = var.sbx_project_id
  region  = var.region
}

data "google_client_config" "current" {}

data "google_project" "edge" {
  project_id = var.edge_project_id
}

data "google_container_cluster" "edge" {
  project  = var.edge_project_id
  name     = var.cluster_name
  location = var.cluster_location
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.edge.endpoint}"
  token                  = data.google_client_config.current.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.edge.master_auth[0].cluster_ca_certificate)
}

