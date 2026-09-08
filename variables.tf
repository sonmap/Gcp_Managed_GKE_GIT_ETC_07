variable "edge_project_id" {
  description = "EDGE PROD project containing the existing GKE Autopilot cluster."
  type        = string
  default     = "pjt-d-shared-base"
}

variable "sbx_project_id" {
  description = "SBX-A data project."
  type        = string
  default     = "pjt-c-admin"
}

variable "region" {
  description = "Google Cloud region."
  type        = string
  default     = "asia-northeast3"
}

variable "cluster_name" {
  description = "Name of the pre-created GKE Autopilot cluster in EDGE PROD."
  type        = string
}

variable "cluster_location" {
  description = "Regional or zonal location of the existing cluster."
  type        = string
  default     = "asia-northeast3"
}

variable "namespace" {
  description = "Kubernetes namespace dedicated to SBX-A."
  type        = string
  default     = "sbx-a"
}

variable "ksa_name" {
  description = "Kubernetes ServiceAccount shared by SBX-A notebook Pods."
  type        = string
  default     = "ksa-jupyter-sbx-a"
}

variable "workspace_domain" {
  description = "Google Workspace domain."
  type        = string
  default     = "sonmap.net"
}

variable "task_group_email" {
  description = "Google Group allowed to use the SBX-A namespace."
  type        = string
  default     = "grp-sbx-a@sonmap.net"
}

variable "users" {
  description = "Five task users. Map keys must be DNS-safe and are used for PVC names."
  type        = map(string)

  validation {
    condition     = length(var.users) == 5
    error_message = "Exactly five users must be supplied for SBX-A."
  }

  validation {
    condition     = alltrue([for email in values(var.users) : endswith(lower(email), "@${lower(var.workspace_domain)}")])
    error_message = "Every user must belong to the configured Google Workspace domain."
  }
}

variable "bigquery_dataset_id" {
  description = "Dataset created for SBX-A."
  type        = string
  default     = "sbx_a"
}

variable "bigquery_location" {
  description = "BigQuery dataset location."
  type        = string
  default     = "asia-northeast3"
}

variable "storage_bucket_name" {
  description = "Globally unique Cloud Storage bucket for SBX-A."
  type        = string
}

variable "storage_location" {
  description = "Cloud Storage bucket location."
  type        = string
  default     = "ASIA-NORTHEAST3"
}

variable "resource_quota" {
  description = "Namespace-wide requested and limit quota."
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
    pods            = string
    pvcs            = string
  })
  default = {
    requests_cpu    = "20"
    requests_memory = "80Gi"
    limits_cpu      = "40"
    limits_memory   = "160Gi"
    pods            = "15"
    pvcs            = "10"
  }
}

variable "notebook_defaults" {
  description = "Default and maximum resources for containers in SBX-A."
  type = object({
    default_cpu       = string
    default_memory    = string
    default_request_cpu    = string
    default_request_memory = string
    max_cpu           = string
    max_memory        = string
  })
  default = {
    default_cpu            = "4"
    default_memory         = "16Gi"
    default_request_cpu    = "2"
    default_request_memory = "8Gi"
    max_cpu                = "8"
    max_memory             = "32Gi"
  }
}

variable "pvc_size" {
  description = "Persistent Disk PVC size for each notebook user."
  type        = string
  default     = "40Gi"
}

variable "pvc_storage_class" {
  description = "StorageClass for user home PVCs."
  type        = string
  default     = "standard-rwo"
}

