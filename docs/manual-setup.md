# Manual foundation — mgmt-01 (Layer 0)

The bits that are **not** automated by this repo: the OS, the cluster, Rancher itself,
and the Cloudflare tunnel. These are one-time, hardware- or account-bound steps. Do them
in order, then deploy the rest with Helmfile via [`bootstrap.md`](./bootstrap.md).

> Why manual: Rancher needs a running cluster before Helm can install it (chicken-and-egg);
> OS/RKE2 are node-local; the Cloudflare tunnel is external-account config. Automating these
> would cost more than it saves on a single management box. Everything *above* this layer is
> in Git as Helm charts + values and deployed with Helmfile.

---

## 1. OS + RKE2 (node-local)
openSUSE **Leap Micro** + **RKE2** on the NUC, per the Obsidian *Fleet Build Runbook*
(Phase 1 — hardware/IP/disk specifics live there, not duplicated here). End state:
- Leap Micro installed, fixed IP set.
- RKE2 server running; `kubectl` (or the RKE2 kubeconfig) works against the node.

## 2. cert-manager (Helm)
Rancher needs cert-manager even when TLS is terminated at Cloudflare.
```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --version vX.Y.Z            # [verify]
```

## 3. Rancher (Helm)
We front Rancher with cloudflared, so TLS is **external** (no in-cluster ingress/LB).
```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
helm install rancher rancher-stable/rancher \
  --namespace cattle-system --create-namespace \
  --set hostname=rancher.cellarwood.org \
  --set bootstrapPassword='<choose-a-strong-one>' \
  --set replicas=1 \
  --set tls=external \              # Cloudflare terminates TLS; Rancher serves plain HTTP
  --set ingress.enabled=false \     # exposure is via cloudflared, not an Ingress
  --version 2.14.x                  # [verify] pin to your line
```
This leaves a ClusterIP `rancher` Service in `cattle-system` on port 80 — that's what the
tunnel points at (§5). Log in once at `https://rancher.cellarwood.org` after §5 to finish
first-run setup.

## 4. agent-tls-mode (required for tls=external imports)
So downstream cluster imports trust the system store rather than Rancher's CA.
```bash
kubectl apply -f - <<'EOF'
apiVersion: management.cattle.io/v3
kind: Setting
metadata:
  name: agent-tls-mode
value: system-store
EOF
```
(Or toggle it in the Rancher UI: *Global Settings → agent-tls-mode → system-store*.)

## 5. Cloudflare tunnel (dashboard) + DNS
Routing lives in the Cloudflare Zero Trust dashboard (decision: dashboard-managed token).

1. **Zero Trust → Networks → Tunnels → Create a tunnel** → connector **Cloudflared** →
   name it `mgmt-01`.
2. **Copy the tunnel token** shown on the install screen (the long `ey...` value). Put it in
   the cloudflared chart's SOPS values overlay — see [`bootstrap.md`](./bootstrap.md) §1:
   ```
   cluster/infra/cloudflared/secrets.enc.yaml  →  tunnel.token
   ```
   (The chart renders it into a Secret; Helm decrypts the overlay in-line at deploy via
   `helm-secrets`. You do **not** install the connector on the host — it runs in-cluster.)
3. **Public Hostnames** — add these (service URLs are in-cluster, since cloudflared runs in
   the cluster). Cloudflare auto-creates the proxied DNS records on `cellarwood.org`:

   | Public hostname | Type | Service URL |
   |---|---|---|
   | `rancher.cellarwood.org` | HTTP | `http://rancher.cattle-system.svc.cluster.local:80` |
   | `grafana.cellarwood.org` | HTTP | `http://rancher-monitoring-grafana.cattle-monitoring-system.svc.cluster.local:80` |

   > `grafana.cellarwood.org` only resolves once the monitoring chart is up (deploy, later).
   > Add it now or when you enable monitoring — either works.

   For remote **SSH + kubectl** over this same tunnel (TCP public hostnames + Cloudflare
   Access), see [`remote-access.md`](./remote-access.md). Optional — skip if LAN-only.

---

## Done → deploy the platform
Foundation is up. Continue with [`bootstrap.md`](./bootstrap.md):
`make namespaces` → secrets (SOPS) → `make deploy` (plain Helm) → Garage init → day-2.
