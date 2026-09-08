#!/usr/bin/env bash
set -euo pipefail

EDGE_PROJECT_ID="${EDGE_PROJECT_ID:-pjt-d-shared-base}"
REGION="${REGION:-asia-northeast3}"
NAMESPACE="${NAMESPACE:-sbx-a}"
CLUSTER_NAME="${CLUSTER_NAME:-sbx-main}"
JUPYTERHUB_CHART_VERSION="${JUPYTERHUB_CHART_VERSION:-4.4.1}"
JUPYTERHUB_RELEASE="${JUPYTERHUB_TEST_RELEASE:-jhub-test}"

for cmd in gcloud kubectl helm; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "ERROR: ${cmd} is not installed." >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values-test-local.yaml"

echo "[1/5] Connecting to ${CLUSTER_NAME}..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --project "${EDGE_PROJECT_ID}"

kubectl get namespace "${NAMESPACE}" >/dev/null
kubectl -n "${NAMESPACE}" get serviceaccount ksa-jupyter-sbx-a >/dev/null

echo "[2/5] Allowing same-namespace traffic for the local smoke test..."
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
EOF

echo "[3/5] Installing local-only JupyterHub smoke-test release..."
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ --force-update
helm repo update
helm upgrade --install "${JUPYTERHUB_RELEASE}" jupyterhub/jupyterhub \
  --version "${JUPYTERHUB_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 15m

echo "[4/5] Current resources..."
kubectl -n "${NAMESPACE}" get pods -o wide
kubectl -n "${NAMESPACE}" get svc
kubectl -n "${NAMESPACE}" get pvc

echo "[5/5] Test instructions"
cat <<'EOF'

============================================================
LOCAL-ONLY JUPYTERHUB TEST

This test does NOT create an Ingress or public Load Balancer.
Do not expose this DummyAuthenticator test release to the Internet.

1) Start port-forward and keep that terminal open:
   kubectl -n sbx-a port-forward svc/proxy-public 8000:80

2) From another terminal on instance-son:
   curl -i http://127.0.0.1:8000/hub/health

3) For browser access, create an SSH tunnel from your PC to instance-son
   or use a browser available on the VM. Then open:
   http://127.0.0.1:8000

Test login:
   username: user01
   password: jupyter-test-only

After clicking Start My Server, verify:
   kubectl -n sbx-a get pods -w
   kubectl -n sbx-a get pvc
   kubectl -n sbx-a get pod jupyter-user01 -o jsonpath='{.spec.serviceAccountName}{"\n"}'

Expected service account:
   ksa-jupyter-sbx-a

When the smoke test is complete, remove the temporary release:
   helm uninstall jhub-test -n sbx-a
============================================================
EOF
