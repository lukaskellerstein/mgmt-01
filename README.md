# mgmt-01-platform

Infrastructure-as-Code and GitOps source of truth for **`mgmt-01`** — the Rancher
management plane of the NUC fleet.

> Architecture & decisions live in `onion-ai-eu/executive-management/infra/`
> (`k8s-fleet-platform-architecture.md`, `nuc-fleet-inventory.md`) and the Obsidian
> *Fleet Build Runbook*. This repo is the **executable** companion to those docs:
> everything `mgmt-01` runs, beyond the manual foundation, is defined here as **Helm charts +
> values** and deployed with **Helmfile**.

---

## What lives on mgmt-01 and why

`mgmt-01` is the **smallest box in the fleet on purpose** (Core 3 N355 / 16 GB) — its
primary job is control-plane reliability (Rancher), so we only add **platform / fleet-
management services**, never business apps. The spare capacity is turned into the fleet's
**observability + backup + registry hub**, which strengthens the single-pane / EU-sovereign
story rather than diluting the control plane.

| Layer | Component | Purpose | Tier |
|---|---|---|---|
| Control plane | Rancher + cert-manager | manage the fleet (manual foundation, not deployed by this repo) | — |
| Connectivity | `cloudflared` | tunnel → `rancher.cellarwood.org`; remote SSH + kubectl ([`docs/remote-access.md`](docs/remote-access.md)) | 0 |
| Backup | `rancher-backup` | protect Rancher state → object store | 1 |
| Object store | **Garage** (EU, S3-compatible) | one store: backups + Thanos + Loki | 1 |
| Observability | kube-prometheus-stack (+ Thanos) + Loki | central fleet metrics & logs | 1 |
| Registry | pull-through cache | LAN image cache → faster node/customer builds | 2 |

> **MinIO was rejected** (community edition deprecated/gutted). We use **Garage** —
> French/EU, Rust, tiny footprint, S3-compatible — which fits the weak box and the
> EU-first thesis.

---

## The model: manual foundation → local Helm charts for everything else

```
   docs/manual-setup.md  │ OS + RKE2 + cert-manager + Rancher (Helm) + CF tunnel │  one-time,
   (Layer 0, manual)     │ — node-local / external-account / chicken-and-egg     │  by hand
                         └──────────────────────────────────────────────────────┘
                                                   │ then
                                                   ▼
   bootstrap/namespaces.yaml │ kubectl apply → declarative namespaces (own them in git) │
                         └────────────────────────────────────────────────────────────┘
                                                   │ then, per chart
                                                   ▼
   cluster/infra/*       │ helm upgrade --install <chart> ./cluster/<tier>/<chart> -n <ns> │
   cluster/platform/*    └────────────────────────────────────────────────────────────────┘
                                                   │ and, per workload cluster
                                                   ▼
   cluster/downstream/observability-agent │ helm ... --kube-context <cluster> → agent │
                         └──────────────────────────────────────────────────────────────┘
```

This matches the rest of the fleet (`home-lab-01`, `onion-*`): **no Fleet, no Helmfile** — every
service is a **local Helm chart** under `cluster/<tier>/<chart>`, deployed with plain
`helm upgrade --install`.

- **Manual foundation (`docs/manual-setup.md`)** — the one-time, node-local or
  external-account config that isn't worth automating on a single box: OS + RKE2, then
  cert-manager + Rancher via **Helm**, and the Cloudflare tunnel via the dashboard.
- **`bootstrap/namespaces.yaml`** — the declarative source of truth for namespaces; apply it
  first, then deploy charts with `-n <ns>` and *without* `--create-namespace`.
- **`cluster/infra/*` + `cluster/platform/*`** — every platform service as a local chart.
  Upstream charts (kube-prometheus-stack, Loki, docker-registry, rancher-backup) are **thin
  wrapper charts** (a `dependencies:` entry + overrides); Garage and the cloudflared connector
  are **first-party charts** with their own templates.
- **`cluster/downstream/observability-agent`** — the light agent for the workload clusters;
  Helm is single-cluster per run, so apply it once per cluster with that kube-context.

This means the **VPS migration in Decision 7 is a redeploy, not a rebuild**: stand up a new
Rancher (Helm), apply the secrets, and `make deploy` repaints the box.

### Deploy

```bash
make namespaces           # kubectl apply -f bootstrap/namespaces.yaml (once, first)
make secrets-apply        # apply every out-of-band Secret (scripts/secrets.py)
# pin every "__REPLACE__" chart version (Chart.yaml dependencies) first   # [verify]
make deploy               # helm upgrade --install every local chart (in order)
make deploy-downstream c=<context>   # observability agent → one workload cluster
```

`make deploy` installs cloudflared **last**, and it deliberately fails until you set its
Cloudflare-issued tunnel token (`sops cluster/infra/cloudflared/secrets.enc.yaml`) — everything
else comes up without it. Tooling: `helm`, `sops`, `age`, and the `helm-secrets` plugin
(`helm plugin install https://github.com/jkroepke/helm-secrets`) for the cloudflared overlay.

---

## Bootstrap order (chicken-and-egg)

Helm can't deploy Rancher onto a box that has no cluster yet, so a thin foundation stays
manual, then plain Helm applies everything else:

1. **Manual foundation** (`docs/manual-setup.md`): Leap Micro + RKE2 (per the Fleet Build
   Runbook) → cert-manager + Rancher via Helm → `agent-tls-mode` → Cloudflare tunnel.
2. **Secrets** (`docs/bootstrap.md` §1): SOPS + age → `make namespaces && make secrets-apply`.
3. **Deploy:** `make deploy` brings up Garage, monitoring, logging, registry-cache and
   rancher-backup on `mgmt-01`.
4. **Downstream:** `make deploy-downstream c=<cluster>` pushes the observability agent to each
   workload cluster as it's imported.
5. **Day-2:** initialise Garage (`docs/bootstrap.md` §3), fill the wave-2 secrets.

---

## Secrets — SOPS + age

**Encrypted secrets live in Git; plaintext never does.** The scheme is **SOPS + age**, the fleet
standard. Secrets are **co-located** with the chart that consumes them
(`cluster/<tier>/<chart>/<name>.enc.yaml`). **Full scheme, keys, tooling and rotation:
[`docs/secrets.md`](docs/secrets.md)** — the workflow runs through
[`scripts/secrets.py`](scripts/secrets.py) (the `make` secret targets delegate to it), and the
fleet recipients are already in `.sops.yaml` (your existing fleet age key decrypts — no per-repo key).

Two file shapes, both SOPS-encrypted in Git:

**A. Out-of-band `Secret`s** — real `kind: Secret` manifests; only `data`/`stringData` is encrypted.
Applied with `./scripts/secrets.py apply` (= `sops -d | kubectl apply`) so **Helm never owns them**.
Charts reference them by name (`existingSecret` / `envFrom` / `credentialSecretName`).

| Secret | Co-located in | Namespace | Wave |
|---|---|---|---|
| `garage-secrets` | `cluster/infra/garage/` | `object-store` | 1 |
| `backup-encryption` | `cluster/platform/rancher-backup/` | `cattle-resources-system` | 1 |
| `garage-s3-creds` | `cluster/platform/rancher-backup/` | `cattle-resources-system` | 2 |
| `thanos-objstore` | `cluster/platform/monitoring/` | `cattle-monitoring-system` | 2 |
| `loki-s3-creds` | `cluster/platform/logging/` | `cattle-logging-system` | 2 |

*Wave 1* secrets can be created up front; *Wave 2* uses the Garage S3 key, imported during Garage
init (`docs/bootstrap.md` §3). All Wave-2 secrets share one Garage app key.

**B. Helm values overlay** — the cloudflared tunnel token
(`cluster/infra/cloudflared/secrets.enc.yaml`, whole-file encrypted). The chart renders the token
into a Secret; Helm decrypts the overlay in-line at deploy via **`helm-secrets`**
(`helm ... -f secrets://...`). The token is **Cloudflare-issued** — the one secret you must supply.

Workflow (`make help` lists all targets; full detail in [`docs/secrets.md`](docs/secrets.md)):

```bash
make sops-edit f=cluster/infra/garage/garage-secrets.enc.yaml   # decrypt → edit → re-encrypt
make secrets-apply                  # apply every out-of-band Secret
make secrets-lint                   # hygiene: no plaintext *.enc.yaml, no stray decrypted files
```

## Versions

Chart/image versions are marked **`# [verify]`** — confirm against upstream at apply time,
same convention as the Fleet Build Runbook.
