#!/usr/bin/env bash
set -euo pipefail

EDGE_PROJECT_ID="${EDGE_PROJECT_ID:-pjt-d-shared-base}"
REGION="${REGION:-asia-northeast3}"
VPC_NAME="${VPC_NAME:-vpc-d-shared-base}"
NAMESPACE="${NAMESPACE:-sbx-a}"
KSA_NAME="${KSA_NAME:-ksa-jupyter-sbx-a}"
PROXY_ONLY_SUBNET_NAME="${PROXY_ONLY_SUBNET_NAME:-subnet-proxy-only}"
PROXY_ONLY_CIDR="${PROXY_ONLY_CIDR:-172.31.22.0/26}"
JUPYTERHUB_ILB_IP_NAME="${JUPYTERHUB_ILB_IP_NAME:-jupyterhub-sbx-a-ilb}"
JUPYTERHUB_ILB_IP="${JUPYTERHUB_ILB_IP:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

for cmd in gcloud kubectl awk; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} is not installed or not in PATH." >&2
    exit 1
  fi
done

echo "[1/6] Discovering the existing Autopilot cluster..."
if [[ -z "${CLUSTER_NAME}" ]]; then
  mapfile -t AUTOPILOT_CLUSTERS < <(
    gcloud container clusters list \
      --project "${EDGE_PROJECT_ID}" \
      --format='csv[no-heading](name,location,autopilot.enabled)' \
    | awk -F',' -v region="${REGION}" '
        $2 == region && tolower($3) == "true" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1 }
      '
  )

  if [[ ${#AUTOPILOT_CLUSTERS[@]} -eq 1 ]]; then
    CLUSTER_NAME="${AUTOPILOT_CLUSTERS[0]}"
  elif [[ ${#AUTOPILOT_CLUSTERS[@]} -eq 0 ]]; then
    echo "ERROR: no regional Autopilot cluster found in ${EDGE_PROJECT_ID}/${REGION}." >&2
    echo "Run: gcloud container clusters list --project ${EDGE_PROJECT_ID}" >&2
    exit 1
  else
    echo "ERROR: more than one Autopilot cluster found in ${EDGE_PROJECT_ID}/${REGION}:" >&2
    printf '  %s\n' "${AUTOPILOT_CLUSTERS[@]}" >&2
    echo "Set CLUSTER_NAME to the cluster containing namespace ${NAMESPACE}." >&2
    exit 1
  fi
fi

echo "Detected cluster: ${CLUSTER_NAME}"

echo "[2/6] Connecting to GKE and verifying SBX-A resources..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}"

kubectl get namespace "${NAMESPACE}" >/dev/null
kubectl -n "${NAMESPACE}" get serviceaccount "${KSA_NAME}" >/dev/null

CLUSTER_NETWORK="$(gcloud container clusters describe "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}" \
  --format='value(network)')"
CLUSTER_SUBNETWORK="$(gcloud container clusters describe "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}" \
  --format='value(subnetwork)')"

CLUSTER_NETWORK_NAME="${CLUSTER_NETWORK##*/}"
CLUSTER_SUBNETWORK_NAME="${CLUSTER_SUBNETWORK##*/}"

if [[ -z "${CLUSTER_NETWORK_NAME}" || -z "${CLUSTER_SUBNETWORK_NAME}" ]]; then
  echo "ERROR: could not discover cluster VPC/subnet." >&2
  exit 1
fi

if [[ "${CLUSTER_NETWORK_NAME}" != "${VPC_NAME}" ]]; then
  echo "WARNING: expected VPC ${VPC_NAME}, but cluster uses ${CLUSTER_NETWORK_NAME}. Using actual cluster VPC." >&2
  VPC_NAME="${CLUSTER_NETWORK_NAME}"
fi

SUBNET_CIDR="$(gcloud compute networks subnets describe "${CLUSTER_SUBNETWORK_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --region "${REGION}" \
  --format='value(ipCidrRange)')"

echo "Cluster VPC    : ${VPC_NAME}"
echo "Cluster subnet : ${CLUSTER_SUBNETWORK_NAME} (${SUBNET_CIDR})"

echo "[3/6] Checking REGIONAL_MANAGED_PROXY subnet..."
PROXY_ROW="$(gcloud compute networks subnets list \
  --project "${EDGE_PROJECT_ID}" \
  --regions "${REGION}" \
  --format='csv[no-heading](name,network,purpose,ipCidrRange)' \
  | awk -F',' -v net="${VPC_NAME}" '$2 == net || $2 ~ ("/" net "$") { if ($3 == "REGIONAL_MANAGED_PROXY") { print $1 "|" $4; exit } }')"

if [[ -z "${PROXY_ROW}" ]]; then
  CONFLICT="$(gcloud compute networks subnets list \
    --project "${EDGE_PROJECT_ID}" \
    --regions "${REGION}" \
    --format='csv[no-heading](name,network,purpose,ipCidrRange)' \
    | awk -F',' -v net="${VPC_NAME}" -v cidr="${PROXY_ONLY_CIDR}" '$4 == cidr && ($2 == net || $2 ~ ("/" net "$")) {print $1 "|" $3; exit}')"

  if [[ -n "${CONFLICT}" ]]; then
    echo "ERROR: ${PROXY_ONLY_CIDR} is already used by subnet ${CONFLICT%%|*} with purpose ${CONFLICT#*|}." >&2
    exit 1
  fi

  echo "Creating ${PROXY_ONLY_SUBNET_NAME} (${PROXY_ONLY_CIDR})..."
  gcloud compute networks subnets create "${PROXY_ONLY_SUBNET_NAME}" \
    --project "${EDGE_PROJECT_ID}" \
    --network "${VPC_NAME}" \
    --region "${REGION}" \
    --range "${PROXY_ONLY_CIDR}" \
    --purpose REGIONAL_MANAGED_PROXY \
    --role ACTIVE

  PROXY_SUBNET_NAME="${PROXY_ONLY_SUBNET_NAME}"
  PROXY_CIDR="${PROXY_ONLY_CIDR}"
else
  PROXY_SUBNET_NAME="${PROXY_ROW%%|*}"
  PROXY_CIDR="${PROXY_ROW#*|}"
  echo "Using existing proxy-only subnet: ${PROXY_SUBNET_NAME} (${PROXY_CIDR})"
fi

echo "[4/6] Reserving regional static internal VIP for JupyterHub..."
if ! gcloud compute addresses describe "${JUPYTERHUB_ILB_IP_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --region "${REGION}" >/dev/null 2>&1; then

  ADDRESS_ARGS=(
    compute addresses create "${JUPYTERHUB_ILB_IP_NAME}"
    --project "${EDGE_PROJECT_ID}"
    --region "${REGION}"
    --subnet "${CLUSTER_SUBNETWORK_NAME}"
    --purpose SHARED_LOADBALANCER_VIP
    --address-type INTERNAL
  )

  # Leave JUPYTERHUB_ILB_IP empty to let Google Cloud choose a free address
  # from the real cluster subnet. This avoids manually picking an address that
  # is already reserved or in use.
  if [[ -n "${JUPYTERHUB_ILB_IP}" ]]; then
    ADDRESS_ARGS+=(--addresses "${JUPYTERHUB_ILB_IP}")
  fi

  gcloud "${ADDRESS_ARGS[@]}"
else
  echo "Static VIP resource already exists: ${JUPYTERHUB_ILB_IP_NAME}"
fi

RESERVED_ILB_IP="$(gcloud compute addresses describe "${JUPYTERHUB_ILB_IP_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --region "${REGION}" \
  --format='value(address)')"

echo "[5/6] Verifying reserved address..."
gcloud compute addresses describe "${JUPYTERHUB_ILB_IP_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --region "${REGION}" \
  --format='table(name,address,addressType,purpose,status,subnetwork.basename())'

echo "[6/6] Values for JupyterHub deployment"
cat <<EOF

============================================================
GKE Autopilot cluster : ${CLUSTER_NAME}
VPC                   : ${VPC_NAME}
GKE/LB subnet         : ${CLUSTER_SUBNETWORK_NAME} (${SUBNET_CIDR})
Proxy-only subnet     : ${PROXY_SUBNET_NAME} (${PROXY_CIDR})
JupyterHub VIP name   : ${JUPYTERHUB_ILB_IP_NAME}
JupyterHub VIP        : ${RESERVED_ILB_IP}

Use these values:
export CLUSTER_NAME="${CLUSTER_NAME}"
export JUPYTERHUB_ILB_IP="${RESERVED_ILB_IP}"
export JUPYTERHUB_PROXY_ONLY_CIDR="${PROXY_CIDR}"

Recommended internal FQDN pattern:
  jupyter-sbx-a.<company-private-domain>

Internal DNS A record:
  jupyter-sbx-a.<company-private-domain> -> ${RESERVED_ILB_IP}

The actual HTTPS Application Load Balancer is created by the GKE
`jupyterhub-internal` Ingress in deploy.sh after the TLS secret and
JupyterHub backend are available.
============================================================
EOF
