# SBX-A JupyterHub / Internal HTTPS

This directory completes the resources that were intentionally missing from the base Terraform configuration:

- JupyterHub Hub and proxy Pods
- Per-user Notebook Pods, spawned on demand after login
- Reuse of the existing `home-user01` ... `home-user05` PVC naming model
- GKE internal Application Load Balancer
- HTTPS using a Kubernetes TLS Secret
- Google OAuth login restricted to an explicit user list and Workspace domain
- NetworkPolicy rules required by the existing namespace-wide default-deny ingress policy

## Resulting flow

```text
Security PC / internal client
        |
        | HTTPS 443
        v
Internal DNS
        |
        | JUPYTERHUB_HOST -> regional 172.x ILB VIP
        v
GKE Internal Application Load Balancer
        |
        | NEG backend
        v
proxy-public Service (ClusterIP)
        |
        v
JupyterHub proxy
        |
        +----> Hub Pod -- Google OAuth login
        |
        +----> Notebook Pod for user01
                  |
                  +---- KSA: ksa-jupyter-sbx-a
                  +---- PVC: home-user01
                  +---- BigQuery / GCS through Workload Identity
```

## Why Notebook Pods do not exist before login

JupyterHub/KubeSpawner creates a Notebook Pod only when a user starts a server. With five configured users, the normal state immediately after installation is therefore:

```text
Hub Pod                 Running
Proxy Pod               Running
Notebook user01         not created until user01 logs in
Notebook user02         not created until user02 logs in
...
```

This avoids keeping five 2-vCPU / 8-GiB requested Notebook Pods running when nobody is using the environment. The idle culler stops a Notebook server after 60 minutes of inactivity.

## Existing PVC reuse

`values.yaml` sets:

```yaml
singleuser:
  storage:
    type: dynamic
    capacity: 40Gi
    dynamic:
      storageClass: standard-rwo
      pvcNameTemplate: home-{username}
```

Because Google OAuth strips the single allowed Workspace domain from the login name, `user01@sonmap.net` becomes JupyterHub user `user01`, and the expected claim is `home-user01`.

The existing `standard-rwo` PVC can remain `Pending` while no Notebook Pod consumes it. With `WaitForFirstConsumer` storage, it binds when the first user Pod is scheduled.

## Prerequisites

The base Terraform must already have created:

```bash
kubectl -n sbx-a get serviceaccount ksa-jupyter-sbx-a
kubectl -n sbx-a get pvc
kubectl -n sbx-a get resourcequota,limitrange,networkpolicy
```

You also need:

- `gcloud`, `kubectl`, and Helm 3
- Existing GKE Autopilot cluster
- A regional proxy-only subnet for the internal Application Load Balancer
- Google OAuth client ID and secret
- Internal DNS name for JupyterHub
- PEM certificate and private key for that DNS name

The Google OAuth client must allow exactly this redirect URI:

```text
https://<JUPYTERHUB_HOST>/hub/oauth_callback
```

## Deploy

Use the feature branch:

```bash
git fetch origin
git checkout feature/jupyterhub-internal-https
```

Set the deployment inputs. The five allowed users can be supplied as full email addresses or short usernames.

```bash
export CLUSTER_NAME="YOUR_EXISTING_AUTOPILOT_CLUSTER"
export EDGE_PROJECT_ID="pjt-d-shared-base"
export REGION="asia-northeast3"

export JUPYTERHUB_HOST="jupyter-sbx-a.internal.example.com"
export JUPYTERHUB_DOMAIN="sonmap.net"
export JUPYTERHUB_ALLOWED_USERS="user01@sonmap.net,user02@sonmap.net,user03@sonmap.net,user04@sonmap.net,user05@sonmap.net"

export GOOGLE_OAUTH_CLIENT_ID="...apps.googleusercontent.com"
export GOOGLE_OAUTH_CLIENT_SECRET="..."

export TLS_CERT_FILE="/secure/path/jupyter-sbx-a.crt"
export TLS_KEY_FILE="/secure/path/jupyter-sbx-a.key"
```

If you have already selected the exact 172.x address, set it before deployment:

```bash
export JUPYTERHUB_ILB_IP="172.31.x.x"
```

If automatic proxy-only subnet discovery is not appropriate, specify it explicitly:

```bash
export JUPYTERHUB_PROXY_ONLY_CIDR="172.31.100.128/26"
```

Run:

```bash
bash jupyterhub/deploy.sh
```

The script performs the following sequence:

1. Gets GKE credentials.
2. Verifies `sbx-a`, the KSA, and existing PVCs.
3. Discovers the cluster network/subnetwork and proxy-only subnet.
4. Reserves a regional internal static VIP.
5. Creates OAuth and TLS Kubernetes Secrets without writing the secret values to Git.
6. Creates a BackendConfig with `/hub/health` health checking.
7. Installs Zero-to-JupyterHub Helm chart `4.4.1`.
8. Adds ingress NetworkPolicies required by the existing default-deny policy.
9. Creates an HTTPS-only `gce-internal` Ingress.

## DNS

After the script prints the reserved internal address, register an internal DNS record:

```text
<JUPYTERHUB_HOST>  ->  <reserved 172.x internal LB IP>
```

For the corporate-network path this normally becomes:

```text
Security PC 172.x
  -> Interconnect
  -> GCP VPC
  -> Internal DNS
  -> GKE internal ALB 172.x:443
  -> proxy-public NEG
  -> JupyterHub
```

## Validation

```bash
kubectl -n sbx-a get pods -o wide
kubectl -n sbx-a get svc proxy-public
kubectl -n sbx-a get ingress jupyterhub-internal
kubectl -n sbx-a describe ingress jupyterhub-internal
kubectl -n sbx-a get backendconfig jupyterhub-backend
kubectl -n sbx-a get networkpolicy
kubectl -n sbx-a get pvc
```

After `user01` logs in and starts JupyterLab:

```bash
kubectl -n sbx-a get pod -o wide | grep user01
kubectl -n sbx-a get pvc home-user01
```

Validate the KSA on the spawned Notebook Pod:

```bash
POD="$(kubectl -n sbx-a get pod -o name | grep user01 | head -n1 | cut -d/ -f2)"
kubectl -n sbx-a get pod "${POD}" -o jsonpath='{.spec.serviceAccountName}{"\n"}'
```

Expected result:

```text
ksa-jupyter-sbx-a
```

## Shared VPC firewall note

Internal GKE Ingress requires health-check and load-balancer traffic to reach the NEG backend. In Shared VPC, if the GKE service account cannot create the host-project firewall rule, GKE records the required firewall command in the Ingress event.

Check:

```bash
kubectl -n sbx-a describe ingress jupyterhub-internal
```

Do not suppress the Shared VPC firewall error until the required firewall rule has actually been implemented by the network team.

## Image-pull note for closed networks

The Helm chart and Notebook containers still need their container images. If the private GKE environment has no usable egress to the public registries used by JupyterHub, mirror the required Hub, proxy, and Notebook images into Artifact Registry and override the chart image repositories before deployment.
