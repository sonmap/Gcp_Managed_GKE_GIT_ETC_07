resource "kubernetes_namespace_v1" "sbx" {
  metadata {
    name = var.namespace
    labels = merge(local.common_labels, {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    })
  }
}

resource "kubernetes_service_account_v1" "jupyter" {
  metadata {
    name      = var.ksa_name
    namespace = kubernetes_namespace_v1.sbx.metadata[0].name
    labels    = local.common_labels
  }

  automount_service_account_token = false
}

resource "kubernetes_role_v1" "notebook_user" {
  metadata {
    name      = "notebook-user"
    namespace = kubernetes_namespace_v1.sbx.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "persistentvolumeclaims"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "task_group" {
  metadata {
    name      = "${var.namespace}-workspace-group"
    namespace = kubernetes_namespace_v1.sbx.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = var.task_group_email
    api_group = "rbac.authorization.k8s.io"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.notebook_user.metadata[0].name
  }
}

resource "kubernetes_resource_quota_v1" "sbx" {
  metadata {
    name      = "${var.namespace}-quota"
    namespace = kubernetes_namespace_v1.sbx.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = var.resource_quota.requests_cpu
      "requests.memory" = var.resource_quota.requests_memory
      "limits.cpu"      = var.resource_quota.limits_cpu
      "limits.memory"   = var.resource_quota.limits_memory
      "pods"            = var.resource_quota.pods
      "persistentvolumeclaims" = var.resource_quota.pvcs
    }
  }
}

resource "kubernetes_limit_range_v1" "sbx" {
  metadata {
    name      = "${var.namespace}-limits"
    namespace = kubernetes_namespace_v1.sbx.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = var.notebook_defaults.default_cpu
        memory = var.notebook_defaults.default_memory
      }
      default_request = {
        cpu    = var.notebook_defaults.default_request_cpu
        memory = var.notebook_defaults.default_request_memory
      }
      max = {
        cpu    = var.notebook_defaults.max_cpu
        memory = var.notebook_defaults.max_memory
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.sbx.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_persistent_volume_claim_v1" "user_home" {
  for_each = var.users

  metadata {
    name      = "home-${each.key}"
    namespace = kubernetes_namespace_v1.sbx.metadata[0].name
    labels = merge(local.common_labels, {
      notebook-user = each.key
    })
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.pvc_storage_class

    resources {
      requests = {
        storage = var.pvc_size
      }
    }
  }

  wait_until_bound = false
}

