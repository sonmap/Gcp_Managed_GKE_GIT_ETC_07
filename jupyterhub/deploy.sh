#!/usr/bin/env bash
set -euo pipefail

EDGE_PROJECT_ID="${EDGE_PROJECT_ID:-pjt-d-shared-base}"
REGION="${REGION:-asia-northeast3}"
NAMESPACE="${NAMESPACE:-sbx-a}"
KSA_NAME="${KSA_NAME:-ksa-jupyter-sbx-a}"
JUPYTERHUB_DOMAIN="${JUPYTERHUB_DOMAIN:-sonmap.net}"
JUPYTERHUB_CHART_VERSION="${JUPYTERHUB_CHART_VERSION:-4.4.1}"
JUPYTERHUB_RELEASE="${JUPYTERHUB_RELEASE:-jhub}"
JUPYTERHUB_ILB_IP_NAME="${JUPYTERHUB_ILB_IP_NAME:-jupyterhub-sbx-a-ilb}"
JUPYTERHUB_ILB_IP="${JUPYTERHUB_ILB_IP:-}"
JUPYTERHUB_PROXY_ONLY_CIDR="${JUPYTERHUB_PROXY_ONLY_CIDR:-}"

required_env=(
  CLUSTER_NAME
  JUPYTERHUB_HOST
  GOOGLE_OAUTH_CLIENT_ID
  GOOGLE_OAUTH_CLIENT_SECRET
  JUPYTERHUB_ALLOWED_USERS
  TLS_CERT_FILE
  TLS_KEY_FILE
)

for name in "${required_env[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: environment variable ${name} is required." >&2
    exit 1
  fi
done

for cmd in gcloud kubectl helm; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} is not installed or not in PATH." >&2
    exit 1
  fi
done

if [[ ! -f "${TLS_CERT_FILE}" ]]; then
  echo "ERROR: TLS_CERT_FILE not found: ${TLS_CERT_FILE}" >&2
  exit 1
fi
if [[ ! -f "${TLS_KEY_FILE}" ]]; then
  echo "ERROR: TLS_KEY_FILE not found: ${TLS_KEY_FILE}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"

printf '\n[1/9] Connecting to GKE cluster...\n'
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}"

kubectl get namespace "${NAMESPACE}" >/dev/null
kubectl -n "${NAMESPACE}" get serviceaccount "${KSA_NAME}" >/dev/null

printf '\nExisting SBX-A PVCs:\n'
kubectl -n "${NAMESPACE}" get pvc -o wide

printf '\n[2/9] Discovering cluster network and proxy-only subnet...\n'
CLUSTER_SUBNETWORK="$(gcloud container clusters describe "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}" \
  --format='value(subnetwork)')"
CLUSTER_NETWORK="$(gcloud container clusters describe "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}" \
  --format='value(network)')"

if [[ -z "${CLUSTER_SUBNETWORK}" ]]; then
  echo "ERROR: could not determine the cluster subnetwork." >&2
  exit 1
fi

if [[ -z "${JUPYTERHUB_PROXY_ONLY_CIDR}" ]]; then
  JUPYTERHUB_PROXY_ONLY_CIDR="$(gcloud compute networks subnets list \
    --project "${EDGE_PROJECT_ID}" \
    --regions "${REGION}" \
    --filter="purpose=REGIONAL_MANAGED_PROXY AND network:${CLUSTER_NETWORK}" \
    --format='value(ipCidrRange)' | head -n 1)"
fi

if [[ -z "${JUPYTERHUB_PROXY_ONLY_CIDR}" ]]; then
  cat >&2 <<'EOF'
ERROR: no REGIONAL_MANAGED_PROXY subnet was found.
Set JUPYTERHUB_PROXY_ONLY_CIDR explicitly, or create a proxy-only subnet for the internal Application Load Balancer.
EOF
  exit 1
fi

printf 'Cluster network      : %s\n' "${CLUSTER_NETWORK}"
printf 'Cluster subnetwork   : %s\n' "${CLUSTER_SUBNETWORK}"
printf 'Proxy-only subnet    : %s\n' "${JUPYTERHUB_PROXY_ONLY_CIDR}"

printf '\n[3/9] Reserving regional internal HTTPS VIP...\n'
if ! gcloud compute addresses describe "${JUPYTERHUB_ILB_IP_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}" >/dev/null 2>&1; then
  address_args=(
    compute addresses create "${JUPYTERHUB_ILB_IP_NAME}"
    --project "${EDGE_PROJECT_ID}"
    --region "${REGION}"
    --subnet "${CLUSTER_SUBNETWORK}"
    --purpose SHARED_LOADBALANCER_VIP
    --address-type INTERNAL
  )
  if [[ -n "${JUPYTERHUB_ILB_IP}" ]]; then
    address_args+=(--addresses "${JUPYTERHUB_ILB_IP}")
  fi
  gcloud "${address_args[@]}"
fi

RESERVED_ILB_IP="$(gcloud compute addresses describe "${JUPYTERHUB_ILB_IP_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}" \
  --format='value(address)')"
printf 'Reserved ILB IP      : %s\n' "${RESERVED_ILB_IP}"

printf '\n[4/9] Creating OAuth and TLS Secrets without committing secret material...\n'
kubectl -n "${NAMESPACE}" create secret generic jupyterhub-auth \
  --from-literal=client_id="${GOOGLE_OAUTH_CLIENT_ID}" \
  --from-literal=client_secret="${GOOGLE_OAUTH_CLIENT_SECRET}" \
  --from-literal=host="${JUPYTERHUB_HOST}" \
  --from-literal=domain="${JUPYTERHUB_DOMAIN}" \
  --from-literal=allowed_users="${JUPYTERHUB_ALLOWED_USERS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret tls jupyterhub-tls \
  --cert="${TLS_CERT_FILE}" \
  --key="${TLS_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

printf '\n[5/9] Creating BackendConfig for JupyterHub health checks...\n'
kubectl apply -f - <<EOF
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: jupyterhub-backend
  namespace: ${NAMESPACE}
spec:
  healthCheck:
    checkIntervalSec: 15
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    type: HTTP
    requestPath: /hub/health
    port: 8000
EOF

printf '\n[6/9] Installing JupyterHub Helm chart %s...\n' "${JUPYTERHUB_CHART_VERSION}"
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ --force-update
helm repo update
helm upgrade --install "${JUPYTERHUB_RELEASE}" jupyterhub/jupyterhub \
  --version "${JUPYTERHUB_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 15m

printf '\n[7/9] Opening only the required ingress paths through the namespace default-deny policy...\n'
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-sbx-a-internal
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-jupyterhub-ilb
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: ${JUPYTERHUB_PROXY_ONLY_CIDR}
        - ipBlock:
            cidr: 35.191.0.0/16
        - ipBlock:
            cidr: 130.211.0.0/22
      ports:
        - protocol: TCP
          port: 8000
EOF

printf '\n[8/9] Creating GKE internal HTTPS Ingress...\n'
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jupyterhub-internal
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: "gce-internal"
    kubernetes.io/ingress.regional-static-ip-name: "${JUPYTERHUB_ILB_IP_NAME}"
    kubernetes.io/ingress.allow-http: "false"
spec:
  tls:
    - hosts:
        - ${JUPYTERHUB_HOST}
      secretName: jupyterhub-tls
  rules:
    - host: ${JUPYTERHUB_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: proxy-public
                port:
                  number: 80
EOF

printf '\n[9/9] Deployment status...\n'
kubectl -n "${NAMESPACE}" get pods -o wide
kubectl -n "${NAMESPACE}" get service proxy-public
kubectl -n "${NAMESPACE}" get ingress jupyterhub-internal
kubectl -n "${NAMESPACE}" get backendconfig jupyterhub-backend
kubectl -n "${NAMESPACE}" get pvc

cat <<EOF

============================================================
JupyterHub deployment submitted.

Internal HTTPS URL : https://${JUPYTERHUB_HOST}
Internal LB IP     : ${RESERVED_ILB_IP}
OAuth callback URI : https://${JUPYTERHUB_HOST}/hub/oauth_callback

Required outside Kubernetes:
1. Register the OAuth callback URI above in the Google OAuth client.
2. Map ${JUPYTERHUB_HOST} -> ${RESERVED_ILB_IP} in internal DNS.
3. If Ingress reports a Shared VPC firewall error, inspect:
   kubectl -n ${NAMESPACE} describe ingress jupyterhub-internal

Notebook Pods are created on demand after each allowed user logs in.
Existing home-userXX PVCs can remain Pending until their first Notebook Pod is scheduled.
============================================================
EOF
