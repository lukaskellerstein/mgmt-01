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

## The model: manual foundation → Helm (Helmfile) for everything else

```
   docs/manual-setup.md  │ OS + RKE2 + cert-manager + Rancher (Helm) + CF tunnel │  one-time,
   (Layer 0, manual)     │ — node-local / external-account / chicken-and-egg     │  by hand
                         └──────────────────────────────────────────────────────┘
                                                   │ then
                                                   ▼
   helmfile.yaml          │ helmfile sync → all platform releases on mgmt-01 (local) │
   values/*.yaml          └─────────────────────────────────────────────────────────┘
                                                   │ and, per workload cluster
                                                   ▼
   helmfile.downstream.yaml │ helmfile sync --kube-context <cluster> → observability agent │
                         └──────────────────────────────────────────────────────────────┘
```

- **Manual foundation (`docs/manual-setup.md`)** — the one-time, node-local or
  external-account config that isn't worth automating on a single box: OS + RKE2, then
  cert-manager + Rancher via **Helm**, and the Cloudflare tunnel via the dashboard. No
  Terraform — `helm` + `kubectl` + documented steps instead.
- **`helmfile.yaml` + `values/*.yaml`** — every platform service on `mgmt-01`, one Helm
  release per component, applied with `helmfile sync`. Charts with no upstream Helm chart
  (Garage, the rancher-backup `Backup` CR) are wrapped in the generic `bedag/raw` chart so
  everything deploys through one tool.
- **`helmfile.downstream.yaml`** — the light observability agent for the workload clusters;
  Helm is single-cluster per run, so apply it once per cluster with that kube-context.

This means the **VPS migration in Decision 7 is a redeploy, not a rebuild**: stand up a new
Rancher (Helm), apply the out-of-band secrets, and `helmfile sync` repaints the box.

### Deploy

```bash
make secrets-apply        # out-of-band secrets first (Helm does not own these)
# pin every "__REPLACE__" chart version in helmfile.yaml   # [verify]
make diff                 # preview        (helmfile diff)
make deploy               # apply all      (helmfile sync)
make deploy-downstream c=<context>   # observability agent → one workload cluster
```

Tooling: `helm`, `helmfile`, and the `helm-secrets` plugin
(`brew install helmfile && helm plugin install https://github.com/jkroepke/helm-secrets`).

---

## Bootstrap order (chicken-and-egg)

Helm can't deploy Rancher onto a box that has no cluster yet, so a thin foundation stays
manual, then Helmfile applies everything else:

1. **Manual foundation** (`docs/manual-setup.md`): Leap Micro + RKE2 (per the Fleet Build
   Runbook) → cert-manager + Rancher via Helm → `agent-tls-mode` → Cloudflare tunnel.
2. **Secrets** (`docs/bootstrap.md` §1): SOPS + age → `make secrets-apply`.
3. **Deploy:** `make deploy` (`helmfile sync`) brings up Garage, monitoring, logging,
   registry-cache and rancher-backup on `mgmt-01`.
4. **Downstream:** `make deploy-downstream c=<cluster>` pushes the observability agent to each
   workload cluster as it's imported.
5. **Day-2:** initialise Garage (`docs/bootstrap.md` §3), fill the wave-2 secrets.

---

## Secrets — SOPS + age

**Encrypted secrets live in Git; plaintext never does.** The chosen scheme is **SOPS + age**
(simplest for a solo operator). Secret *values* are encrypted; metadata stays readable so
you can review which secret a file defines without decrypting it.

```
secrets/
├── <name>.example.yaml   # committed — the shape, with fake values (documentation)
└── <name>.enc.yaml       # committed — SOPS-encrypted real values (you create these)
```

There are two ways a secret reaches a workload, both SOPS-encrypted in Git:

**A. Out-of-band `Secret`s** (`secrets/*.enc.yaml` → `make secrets-apply` → `kubectl apply`).
Charts reference them (`existingSecret` / `envFrom` / `credentialSecretName`); Helm never owns
them, so a `helmfile sync` can't clobber a live value.

| Secret | Namespace | Wave | Holds |
|---|---|---|---|
| `garage-secrets` | `object-store` | 1 | Garage RPC secret + admin token |
| `backup-encryption` | `cattle-resources-system` | 1 | rancher-backup at-rest key |
| `garage-s3-creds` | `cattle-resources-system` | 2 | Garage S3 key for rancher-backup |
| `thanos-objstore` | `cattle-monitoring-system` | 2 | Garage S3 config for Thanos |
| `loki-s3-creds` | `cattle-logging-system` | 2 | Garage S3 key for Loki |

*Wave 1* secrets can be created up front; *Wave 2* needs the Garage S3 key, which only
exists after Garage is initialised (`docs/bootstrap.md` §3).

**B. Helm values overlay** — the cloudflared tunnel token (`values/secrets/cloudflared-token.enc.yaml`).
The chart takes the token as a plain value, so Helmfile decrypts the overlay in-line at deploy
via the **`helm-secrets`** plugin and merges it over `values/cloudflared.yaml` — no k8s `Secret`.

Workflow (`make help` lists all targets):

```bash
make age-init                       # generate age/keys.txt, print recipient → paste into .sops.yaml
cp secrets/garage-secrets.example.yaml secrets/garage-secrets.enc.yaml
make sops-edit f=garage-secrets     # fill values; saved encrypted in place
make secrets-apply                  # decrypt + kubectl apply all secrets/*.enc.yaml
```

## Versions

Chart/image versions are marked **`# [verify]`** — confirm against upstream at apply time,
same convention as the Fleet Build Runbook.
