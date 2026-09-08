# EDGE PROD GKE / SBX-A Terraform

This repository provisions one task environment across two existing Google Cloud projects:

- **EDGE PROD:** `pjt-d-shared-base` — existing GKE Autopilot cluster and namespace `sbx-a`
- **SBX-A:** `pjt-c-admin` — BigQuery dataset, Cloud Storage bucket, and IAM
- **Workspace:** `sonmap.net` — task Google Group and five existing users

It deliberately does **not** create or take ownership of the existing Autopilot cluster. Terraform reads the cluster as a data source, then creates only tenant resources in it.

## Identity model

```text
five Workspace users
  -> grp-sbx-a@sonmap.net
     -> Jupyter/portal authorization
     -> Kubernetes RoleBinding in namespace sbx-a (only when kubectl access is allowed)

Notebook Pod
  -> KSA system:serviceaccount:sbx-a:ksa-jupyter-sbx-a
     -> Workload Identity Federation principal from pjt-d-shared-base
        -> IAM on pjt-c-admin
           -> BigQuery dataset sbx_a
           -> Cloud Storage bucket
```

The users are not mapped to the KSA. The group controls who may enter the task environment; the KSA controls what the notebook workload may access.

## Repository layout

```text
.
├── gke.tf                 # namespace, KSA, RBAC, quotas, policy, five PVCs
├── data.tf                # SBX-A dataset and bucket
├── iam.tf                 # cross-project KSA principal IAM
├── providers.tf           # existing cluster lookup and provider aliases
├── terraform.tfvars.example
└── workspace/             # Workspace group and members; separate state
```

## Prerequisites

1. The Autopilot cluster already exists in `pjt-d-shared-base`.
2. The Terraform caller can read the cluster and create resources in it.
3. The caller can create BigQuery, Storage, and resource-level IAM in `pjt-c-admin`.
4. The GKE cluster is configured with Google Groups for RBAC using `gke-security-groups@sonmap.net` if users will use `kubectl`.
5. The five users already exist in Google Workspace.
6. Workspace automation uses a dedicated service account with Domain-Wide Delegation. Do not commit its JSON key.

Autopilot already has Workload Identity Federation for GKE enabled. The federated KSA principal is calculated from the **EDGE PROD project number**, namespace, and KSA name.

## 1. Create Workspace group and membership

The Workspace state is separate because it uses Admin SDK credentials, not normal Google Cloud project IAM.

```bash
cd workspace
cp terraform.tfvars.example terraform.tfvars
```

Edit the Workspace customer ID and five real user addresses. Configure the key outside Git:

```bash
export GOOGLEWORKSPACE_CREDENTIALS="/secure/path/workspace-dwd-sa.json"
export GOOGLEWORKSPACE_IMPERSONATED_USER_EMAIL="admin@sonmap.net"

terraform init
terraform plan
terraform apply
```

The Domain-Wide Delegation client must have exactly these scopes:

```text
https://www.googleapis.com/auth/admin.directory.group
https://www.googleapis.com/auth/admin.directory.group.member
```

If `gke-security-groups@sonmap.net` already exists, set `create_gke_security_group = false`. Add/import the child group membership under the existing parent using the organization's chosen Workspace state rather than trying to create a duplicate group.

## 2. Provision SBX-A data and GKE tenant resources

From the repository root:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Set the real Autopilot cluster name, five user addresses, and a globally unique bucket name, then run:

```bash
gcloud auth application-default login
gcloud container clusters get-credentials GKE_CLUSTER_NAME \
  --region asia-northeast3 \
  --project pjt-d-shared-base

terraform init
terraform plan
terraform apply
```

## Resources created

### `pjt-d-shared-base`

- Namespace `sbx-a`
- KSA `ksa-jupyter-sbx-a`
- Google Group RoleBinding
- ResourceQuota and LimitRange
- Default-deny ingress NetworkPolicy
- Five user-home PVCs, 40 GiB each

### `pjt-c-admin`

- BigQuery dataset `sbx_a`
- Cloud Storage bucket with uniform access, public-access prevention, and versioning
- `roles/bigquery.jobUser` for the KSA principal at project level
- `roles/bigquery.dataEditor` for the KSA principal on dataset `sbx_a`
- `roles/storage.objectUser` for the KSA principal on the task bucket

## Important operational notes

- The default-deny policy blocks unsolicited ingress. Add explicit policies for the JupyterHub/proxy namespace after confirming its namespace labels and ports.
- The code does not deploy an unauthenticated Jupyter server. Connect the namespace, shared KSA, and per-user PVCs to the organization's authenticated JupyterHub profile/spawner.
- Five users share the task KSA, so Google Cloud data audit logs identify the task workload principal rather than an individual user. Create one KSA per user if data-plane audit and authorization must be user-specific.
- `terraform destroy` can delete the Namespace and PVC objects. The bucket uses `force_destroy = false`, and the dataset uses `delete_contents_on_destroy = false`, preventing accidental deletion while data remains.

## Validation commands

```bash
kubectl get namespace sbx-a
kubectl -n sbx-a get serviceaccount,role,rolebinding,resourcequota,limitrange,networkpolicy,pvc

terraform output ksa_principal

gcloud projects get-iam-policy pjt-c-admin \
  --flatten="bindings[].members" \
  --filter="bindings.members:ksa-jupyter-sbx-a" \
  --format="table(bindings.role,bindings.members)"
```

