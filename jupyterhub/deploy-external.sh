#!/usr/bin/env bash
set -euo pipefail

EDGE_PROJECT_ID="${EDGE_PROJECT_ID:-pjt-d-shared-base}"
REGION="${REGION:-asia-northeast3}"
NAMESPACE="${NAMESPACE:-sbx-a}"
KSA_NAME="${KSA_NAME:-ksa-jupyter-sbx-a}"
JUPYTERHUB_CHART_VERSION="${JUPYTERHUB_CHART_VERSION:-4.4.1}"
JUPYTERHUB_RELEASE="${JUPYTERHUB_RELEASE:-jhub}"
JUPYTERHUB_EXTERNAL_IP_NAME="${JUPYTERHUB_EXTERNAL_IP_NAME:-jupyterhub-sbx-a-external-ip}"

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
  command -v "${cmd}" >/dev/null 2>&1 || { echo "ERROR: ${cmd} is not installed." >&2; exit 1; }
done

[[ -f "${TLS_CERT_FILE}" ]] || { echo "ERROR: TLS_CERT_FILE not found: ${TLS_CERT_FILE}" >&2; exit 1; }
[[ -f "${TLS_KEY_FILE}" ]] || { echo "ERROR: TLS_KEY_FILE not found: ${TLS_KEY_FILE}" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"

echo "[1/8] Connecting to GKE cluster..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}"

kubectl get namespace "${NAMESPACE}" >/dev/null
kubectl -n "${NAMESPACE}" get serviceaccount "${KSA_NAME}" >/dev/null

echo "[2/8] Verifying global static external IP..."
gcloud compute addresses describe "${JUPYTERHUB_EXTERNAL_IP_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --global >/dev/null

EXTERNAL_IP="$(gcloud compute addresses describe "${JUPYTERHUB_EXTERNAL_IP_NAME}" \
  --project "${EDGE_PROJECT_ID}" \
  --global \
  --format='value(address)')"
echo "External IP: ${EXTERNAL_IP}"

echo "[3/8] Creating OAuth/TLS Secrets..."
kubectl -n "${NAMESPACE}" create secret generic jupyterhub-auth \
  --from-literal=client_id="${GOOGLE_OAUTH_CLIENT_ID}" \
  --from-literal=client_secret="${GOOGLE_OAUTH_CLIENT_SECRET}" \
  --from-literal=host="${JUPYTERHUB_HOST}" \
  --from-literal=allowed_users="${JUPYTERHUB_ALLOWED_USERS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret tls jupyterhub-tls \
  --cert="${TLS_CERT_FILE}" \
  --key="${TLS_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[4/8] Creating BackendConfig..."
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

echo "[5/8] Installing/upgrading JupyterHub..."
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ --force-update
helm repo update
helm upgrade --install "${JUPYTERHUB_RELEASE}" jupyterhub/jupyterhub \
  --version "${JUPYTERHUB_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 15m

echo "[6/8] Allowing external GFE/health-check traffic through Kubernetes NetworkPolicy..."
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-jupyterhub-external-gfe
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 35.191.0.0/16
        - ipBlock:
            cidr: 130.211.0.0/22
      ports:
        - protocol: TCP
          port: 8000
EOF

echo "[7/8] Creating EXTERNAL HTTPS GKE Ingress..."
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jupyterhub-external
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.global-static-ip-name: "${JUPYTERHUB_EXTERNAL_IP_NAME}"
    kubernetes.io/ingress.allow-http: "false"
spec:
  tls:
    - hosts:
        - ${JUPYTERHUB_HOST}
      secretName: jupyterhub-tls
  defaultBackend:
    service:
      name: proxy-public
      port:
        number: 80
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

echo "[8/8] Deployment status..."
kubectl -n "${NAMESPACE}" get pods -o wide
kubectl -n "${NAMESPACE}" get service proxy-public
kubectl -n "${NAMESPACE}" get ingress jupyterhub-external
kubectl -n "${NAMESPACE}" get backendconfig jupyterhub-backend

cat <<EOF

============================================================
External Public IP    : ${EXTERNAL_IP}
External HTTPS host   : https://${JUPYTERHUB_HOST}
OAuth callback URI    : https://${JUPYTERHUB_HOST}/hub/oauth_callback

DNS:
  ${JUPYTERHUB_HOST} -> ${EXTERNAL_IP}

The external Ingress uses class 'gce' and the reserved GLOBAL static IP.
The previous internal VIP/Ingress can remain in place independently.
============================================================
EOF
