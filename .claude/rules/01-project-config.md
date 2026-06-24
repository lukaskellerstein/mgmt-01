# Project Config

- **Project**: `mgmt-01` — the **Rancher management plane** of the NUC fleet. A single-node
  RKE2 cluster whose primary job is control-plane reliability (Rancher), with its spare capacity
  turned into the fleet's **observability + backup + registry hub**. This repo holds **everything**
  `mgmt-01` runs above the manual foundation: local Helm charts, secrets, scripts, docs.
  It hosts **no business workloads** — platform / fleet-management services only.

## Server & access

| | |
|---|---|
| **Hostname / user** | `mgmt-01` · node user per the Fleet Build Runbook |
| **Hardware** | NUC (deliberately the smallest box in the fleet) · Intel Core 3 N355 · 16 GB RAM |
| **OS** | openSUSE Leap Micro — immutable / transactional; host changes via `transactional-update` + reboot (never `zypper` into the running system) |
| **Kubernetes** | **RKE2** (single node: control-plane + etcd + worker), containerd runtime |
| **Control plane** | **Runs Rancher itself** (`cattle-system`, manual Helm install — see [`docs/manual-setup.md`](../../docs/manual-setup.md)) + cert-manager; manages downstream clusters (Fleet) |
| **Domain** | `*.cellarwood.org` (Cloudflare) |
| **Object store** | **Garage** (EU, S3-compatible, single-node ⇒ non-durable — needs an off-site mirror) in `object-store`; backing store for rancher-backup + Thanos + Loki |
| **Ingress / edge** | **No in-cluster ingress controller.** In-cluster `cloudflared` (dashboard-managed token tunnel `mgmt-01`) routes public hostnames straight to **ClusterIP Services**; TLS terminates at the Cloudflare edge |
| **Day-2 / patching** | native Leap Micro (`transactional-update.timer` + `rebootmgr`); k8s upgrades via Rancher / SUC |
| **LOCAL — on the LAN** | SSH to the node · kubectl against the RKE2 API on the node's fixed IP (`https://<nuc-ip>:6443`) |
| **REMOTE — anywhere** | SSH `ssh mgmt-01` (→ `ssh.cellarwood.org`, Cloudflare Access) · kubectl via `cloudflared access tcp --hostname k8s.cellarwood.org --url 127.0.0.1:6443`, then a kubeconfig pointing at `https://127.0.0.1:6443` |

Remote SSH/kubectl ride the **same** cloudflared tunnel that fronts `rancher.cellarwood.org`,
exposed as **TCP public hostnames** (`ssh.cellarwood.org`, `k8s.cellarwood.org`) and gated by
**Cloudflare Access** (email allow-list) — no inbound firewall hole on the NUC. Full setup in
[`docs/remote-access.md`](../../docs/remote-access.md).

**LOCAL vs REMOTE — try BOTH before declaring the node down.** The LAN path only works from the
home LAN; off-LAN it fails immediately (`Network is unreachable` / `Connection refused` / TCP
timeout). **That failure is NOT an outage** — bring up the cloudflared forwarder and retry before
reporting the node or cluster unreachable.

- **First remote hit needs an interactive Cloudflare Access login — a HUMAN step you CANNOT
  perform.** When `cloudflared access …` (or `ssh mgmt-01`) prints a `*.cloudflareaccess.com` URL,
  it is blocked waiting for a one-time login (valid ~24h): the user opens the URL, enters their
  allow-listed email, gets a code by email, and pastes it back. **Surface the URL to the user, then
  STOP and wait** — do not kill the forwarder, tighten its timeout, retry in a tight loop, or report
  the node unreachable while this is pending.
- **kubectl context naming.** RKE2's shipped kubeconfig (`/etc/rancher/rke2/rke2.yaml`) names its
  context `default`. The fleet convention — and what `scripts/secrets.py` guards on — is a context
  named **`mgmt-01`** (and `mgmt-01-remote` for the tunnel forwarder). Rename your context to match,
  or override the guard with `SECRETS_KUBE_CONTEXT`. **Always verify `kubectl config current-context`
  before any mutation** — this box is the Rancher control plane and your kubeconfig also holds the
  downstream clusters.

## Edge, ingress, storage

- **Edge**: `cloudflared` runs **in-cluster** (namespace `cloudflared`, first-party chart
  `cluster/infra/cloudflared`) — tunnel `mgmt-01`, **dashboard-managed token**. The token is a SOPS
  helm-secrets *values* overlay (`cluster/infra/cloudflared/secrets.enc.yaml`), decrypted in-line by
  Helm at deploy (`-f secrets://...`); the chart renders it into a Secret. Public hostnames and Access
  apps are managed **Cloudflare-side**; the chart only runs the connector.
- **Public hostnames** (Cloudflare Zero Trust dashboard) route to **in-cluster Services**:
  `rancher.cellarwood.org` → `rancher.cattle-system.svc:80`,
  `grafana.cellarwood.org` → `rancher-monitoring-grafana.cattle-monitoring-system.svc:80`,
  plus the TCP `ssh.cellarwood.org` / `k8s.cellarwood.org`. **No `IngressRoute`/`Ingress` objects,
  no NodePorts** — to expose a new HTTP service, add a dashboard public hostname pointing at its
  ClusterIP Service.
- **Storage**: **Garage** (object store) provides S3; for PVCs the node uses RKE2's local storage.
  Garage is single-node and **non-durable** — schedule an off-site mirror of the critical buckets
  (`rancher-backup`, `thanos`, `loki`, `backups`); don't let `mgmt-01` hold the only copy of its own backups.
- **Secrets**: SOPS+age, committed encrypted (`*.enc.yaml`), never imperative, never Vault. Full
  strategy in [`docs/secrets.md`](../../docs/secrets.md); tooling is `scripts/secrets.py`. Secrets are
  **co-located** with their chart (`cluster/<tier>/<chart>/<name>.enc.yaml`). Two shapes: out-of-band
  k8s Secret manifests (only `data`/`stringData` encrypted, applied via `secrets.py apply`) and the
  cloudflared helm-secrets values overlay (`cluster/infra/cloudflared/secrets.enc.yaml`, whole file
  encrypted, rendered by its chart).

## Layout (authoritative shape — `README.md` mirrors this for humans; keep both in sync)

- `bootstrap/namespaces.yaml` — declarative namespaces (apply first; charts deploy with `-n <ns>`,
  no `--create-namespace`).
- `cluster/infra/*` — `cloudflared` (first-party), `garage` (first-party), `registry-cache` (wrapper).
- `cluster/platform/*` — `monitoring` (kube-prometheus-stack wrapper, +Thanos), `logging` (Loki
  wrapper), `rancher-backup` (operator wrapper + its `Backup` CR template). One local chart per component.
- `cluster/downstream/observability-agent` — the light agent pushed to each **downstream** workload
  cluster (Helm is single-cluster per run; apply once per `--kube-context`).
- Each chart is a local Helm chart (`Chart.yaml` + `values.yaml` [+ `templates/`]); upstream charts
  are thin wrappers via a `dependencies:` entry. Secrets are co-located `*.enc.yaml`.
- `scripts/` — automation (Python preferred); `scripts/secrets.py` is the SOPS workflow tool.
- `docs/` — [`manual-setup.md`](../../docs/manual-setup.md) (Layer 0), [`bootstrap.md`](../../docs/bootstrap.md)
  (deploy + day-2), [`secrets.md`](../../docs/secrets.md), [`remote-access.md`](../../docs/remote-access.md).
- `Makefile` — thin wrapper: `make namespaces/deploy/deploy-downstream` (plain Helm) and the secret
  targets (which delegate to `scripts/secrets.py`).

- **Deployment style**: **manual foundation → local Helm charts for everything else.** Layer 0 (OS +
  RKE2 + cert-manager + Rancher + Cloudflare tunnel) is one-time and manual
  ([`docs/manual-setup.md`](../../docs/manual-setup.md)). Everything above it is `helm upgrade --install`
  per chart (`make deploy`), matching the rest of the fleet. **No Helmfile, no Terraform.** This repo is
  the source of truth, so a VPS migration is a *redeploy*, not a rebuild.
- **Multi-context warning**: your workstation kubeconfig holds several clusters (`mgmt-01` plus every
  downstream — e.g. `home-lab-01`, `onion-prod-01`, `onion-demo-01`). **Always** verify
  `kubectl config current-context` before any mutation, or pass `--kube-context mgmt-01`. From this
  repo you mutate **`mgmt-01`** (and, deliberately and explicitly, push the observability agent to a
  downstream via `make deploy-downstream c=<context>`); **never** reconfigure a downstream cluster's
  own workloads from here.
