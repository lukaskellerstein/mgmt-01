# mgmt-01-platform

Infrastructure-as-Code and GitOps source of truth for **`mgmt-01`** — the Rancher
management plane of the NUC fleet.

> Architecture & decisions live in `onion-ai-eu/executive-management/infra/`
> (`k8s-fleet-platform-architecture.md`, `nuc-fleet-inventory.md`) and the Obsidian
> *Fleet Build Runbook*. This repo is the **executable** companion to those docs:
> everything `mgmt-01` runs, beyond the bootstrap, is defined here and reconciled by Fleet.

---

## What lives on mgmt-01 and why

`mgmt-01` is the **smallest box in the fleet on purpose** (Core 3 N355 / 16 GB) — its
primary job is control-plane reliability (Rancher), so we only add **platform / fleet-
management services**, never business apps. The spare capacity is turned into the fleet's
**observability + backup + registry hub**, which strengthens the single-pane / EU-sovereign
story rather than diluting the control plane.

| Layer | Component | Purpose | Tier |
|---|---|---|---|
| Control plane | Rancher + cert-manager | manage the fleet (bootstrap, not in this repo's Fleet scope) | — |
| Connectivity | `cloudflared` | tunnel → `rancher.cellarwood.org`; remote SSH + kubectl ([`docs/remote-access.md`](docs/remote-access.md)) | 0 |
| Backup | `rancher-backup` | protect Rancher state → object store | 1 |
| Object store | **Garage** (EU, S3-compatible) | one store: backups + Thanos + Loki | 1 |
| Observability | kube-prometheus-stack (+ Thanos) + Loki | central fleet metrics & logs | 1 |
| Registry | pull-through cache | LAN image cache → faster node/customer builds | 2 |

> **MinIO was rejected** (community edition deprecated/gutted). We use **Garage** —
> French/EU, Rust, tiny footprint, S3-compatible — which fits the weak box and the
> EU-first thesis.

---

## The model: manual foundation → Fleet for everything else

```
   docs/manual-setup.md  │ OS + RKE2 + cert-manager + Rancher (Helm) + CF tunnel │  one-time,
   (Layer 0, manual)     │ — node-local / external-account / chicken-and-egg     │  by hand
                         └──────────────────────────────────────────────────────┘
                                                   │ then
                                                   ▼
   bootstrap/*.yaml       │ kubectl apply → two Fleet GitRepos (point back at this repo) │
                         └─────────────────────────────────────────────────────────────┘
                                                   │ creates
                                                   ▼
                         ┌─────────────────────────────────────────────┐
   fleet/local   │ GitRepo (ns: fleet-local)  → mgmt-01 itself  │  ← Fleet reconciles
   fleet/downstr │ GitRepo (ns: fleet-default)→ home/onion nodes │     this repo
                         └─────────────────────────────────────────────┘
```

- **Manual foundation (`docs/manual-setup.md`)** — the one-time, node-local or
  external-account config that isn't worth automating on a single box: OS + RKE2, then
  cert-manager + Rancher via **Helm**, and the Cloudflare tunnel via the dashboard. No
  Terraform — `helm` + `kubectl` + documented steps instead.
- **`bootstrap/*.yaml`** — two Fleet `GitRepo` objects, applied once with `kubectl`, that
  hand control of the cluster(s) back to this repo.
- **Fleet (`fleet/`)** does everything declarative and in-cluster. `fleet/local/*` targets
  the `mgmt-01` **local** cluster (via the built-in `fleet-local` workspace);
  `fleet/downstream/*` pushes the observability agents to the workload clusters.

This means the **VPS migration in Decision 7 is a redeploy, not a rebuild**: stand up a new
Rancher (Helm), `kubectl apply -f bootstrap/` to re-register this same repo, and Fleet
repaints the box.

---

## Bootstrap order (chicken-and-egg)

Fleet can't deploy Rancher because Fleet ships *inside* Rancher. So a thin foundation stays
manual, then GitOps takes over:

1. **Manual foundation** (`docs/manual-setup.md`): Leap Micro + RKE2 (per the Fleet Build
   Runbook) → cert-manager + Rancher via Helm → `agent-tls-mode` → Cloudflare tunnel.
2. **Secrets** (`docs/bootstrap.md` §1): SOPS + age → `make secrets-apply`.
3. **Hand off to Fleet:** `kubectl apply -f bootstrap/` → the two `GitRepo`s.
4. **Fleet reconciles** `fleet/local/*` onto `mgmt-01`, then `fleet/downstream/*` onto the
   workload clusters as they're imported.
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

| Secret | Namespace | Wave | Holds |
|---|---|---|---|
| `garage-secrets` | `object-store` | 1 | Garage RPC secret + admin token |
| `tunnel-token` | `cloudflared` | 1 | Cloudflare Tunnel token |
| `backup-encryption` | `cattle-resources-system` | 1 | rancher-backup at-rest key |
| `garage-s3-creds` | `cattle-resources-system` | 2 | Garage S3 key for rancher-backup |
| `thanos-objstore` | `cattle-monitoring-system` | 2 | Garage S3 config for Thanos |
| `loki-s3-creds` | `cattle-logging-system` | 2 | Garage S3 key for Loki |

*Wave 1* secrets can be created up front; *Wave 2* needs the Garage S3 key, which only
exists after Garage is initialised (`docs/bootstrap.md` §3).

> **Fleet does not decrypt SOPS.** Unlike Flux/ArgoCD, Rancher Fleet has no native SOPS
> support, so secrets are applied **out of band** with `make secrets-apply` (decrypt →
> `kubectl apply`) during bootstrap and on rotation — Fleet reconciles everything else.
> The inline `Secret` blocks were therefore removed from the Fleet bundles so Fleet can't
> clobber the live values. (If you later want secrets reconciled by Fleet too, switch to
> **Sealed Secrets** — committable `SealedSecret` CRs decrypted by an in-cluster controller.)

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
