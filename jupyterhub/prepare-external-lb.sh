#!/usr/bin/env bash
set -euo pipefail

EDGE_PROJECT_ID="${EDGE_PROJECT_ID:-pjt-d-shared-base}"
REGION="${REGION:-asia-northeast3}"
NAMESPACE="${NAMESPACE:-sbx-a}"
KSA_NAME="${KSA_NAME:-ksa-jupyter-sbx-a}"
EXTERNAL_IP_NAME="${EXTERNAL_IP_NAME:-jupyterhub-sbx-a-external-ip}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

for cmd in gcloud kubectl awk; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "ERROR: ${cmd} is not installed." >&2; exit 1; }
done

echo "[1/4] Discovering existing Autopilot cluster..."
if [[ -z "${CLUSTER_NAME}" ]]; then
  mapfile -t AUTOPILOT_CLUSTERS < <(
    gcloud container clusters list \
      --project "${EDGE_PROJECT_ID}" \
      --format='csv[no-heading](name,location,autopilot.enabled)' \
    | awk -F',' -v region="${REGION}" '$2 == region && tolower($3) == "true" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1}'
  )

  if [[ ${#AUTOPILOT_CLUSTERS[@]} -eq 1 ]]; then
    CLUSTER_NAME="${AUTOPILOT_CLUSTERS[0]}"
  elif [[ ${#AUTOPILOT_CLUSTERS[@]} -eq 0 ]]; then
    echo "ERROR: no Autopilot cluster found in ${EDGE_PROJECT_ID}/${REGION}." >&2
    exit 1
  else
    echo "ERROR: multiple Autopilot clusters found. Set CLUSTER_NAME explicitly:" >&2
    printf '  %s\n' "${AUTOPILOT_CLUSTERS[@]}" >&2
    exit 1
  fi
fi

echo "Detected cluster: ${CLUSTER_NAME}"

echo "[2/4] Verifying namespace and KSA..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}"
kubectl get namespace "${NAMESPACE}" >/dev/null
kubectl -n "${NAMESPACE}" get serviceaccount "${KSA_NAME}" >/dev/null

echo "[3/4] Reserving GLOBAL static external IPv4 address..."
if ! gcloud compute addresses describe "${EXTERNAL_IP_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --global >/dev/null 2>&1; then
  gcloud compute addresses create "${EXTERNAL_IP_NAME}" \
    --project "${EDGE_PROJECT_ID}" \
    --global \
    --ip-version=IPV4
else
  echo "Global external IP resource already exists: ${EXTERNAL_IP_NAME}"
fi

EXTERNAL_IP="$(gcloud compute addresses describe "${EXTERNAL_IP_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --global \
  --format='value(address)')"

echo "[4/4] External VIP ready"
gcloud compute addresses describe "${EXTERNAL_IP_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --global \
  --format='table(name,address,addressType,ipVersion,status)'

cat <<EOF

============================================================
GKE Autopilot cluster : ${CLUSTER_NAME}
External IP name      : ${EXTERNAL_IP_NAME}
External Public IP    : ${EXTERNAL_IP}

Use these values:
export CLUSTER_NAME="${CLUSTER_NAME}"
export JUPYTERHUB_EXTERNAL_IP_NAME="${EXTERNAL_IP_NAME}"
export JUPYTERHUB_EXTERNAL_IP="${EXTERNAL_IP}"

The public IP can be reserved without a DNS name.
For production JupyterHub login over Google OAuth, map a public FQDN you own
to this IP and use HTTPS. The hosted-domain restriction has been removed;
access is restricted by JUPYTERHUB_ALLOWED_USERS instead.
============================================================
EOF
