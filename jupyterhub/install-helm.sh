#!/usr/bin/env bash
set -euo pipefail

if command -v helm >/dev/null 2>&1; then
  echo "Helm is already installed:"
  helm version
  exit 0
fi

for cmd in curl bash; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "ERROR: ${cmd} is required to install Helm." >&2
    exit 1
  }
done

TMP_SCRIPT="$(mktemp)"
trap 'rm -f "${TMP_SCRIPT}"' EXIT

# Zero-to-JupyterHub chart 4.4.1 requires Helm >= 3.5.
# Use the official Helm 3 installer rather than Helm 4 for compatibility.
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "${TMP_SCRIPT}"
chmod 700 "${TMP_SCRIPT}"

# The official installer normally places helm in /usr/local/bin and may use sudo.
"${TMP_SCRIPT}"

echo
helm version
