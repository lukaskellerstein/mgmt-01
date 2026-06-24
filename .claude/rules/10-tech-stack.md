# Reference: Technology Stack

> **Cluster identity, access (LAN/remote), edge/cloudflared, object store, and day-2/OS-patching
> are in [`rules/01-project-config.md`](01-project-config.md).** This file is the **stack &
> conventions** reference. (Runtime: containerd, bundled with RKE2.)

## Packaging & deployment

- **Plain Helm v3** — the deploy tool for `mgmt-01`, matching the rest of the fleet (home-lab-01,
  onion-*). Every platform service is a **local Helm chart** under `cluster/<infra|platform>/<chart>`,
  deployed with `helm upgrade --install <release> ./cluster/<tier>/<chart> -n <ns>` (via `make deploy`).
  **No Helmfile, no Fleet.**
- **Wrapper charts** — upstream charts (rancher-backup, kube-prometheus-stack, Loki, docker-registry,
  prometheus-agent) are thin wrappers: a `dependencies:` entry in `Chart.yaml` + overrides keyed under
  the dependency name in `values.yaml`. Run `helm dependency build` before deploying.
- **First-party charts** — Garage and the cloudflared connector have their own `templates/` (no
  upstream chart). The rancher-backup chart also carries its `Backup` CR as a template.
- **`helm-secrets`** plugin — decrypts the cloudflared SOPS values overlay in-line at deploy
  (`helm ... -f secrets://cluster/infra/cloudflared/secrets.enc.yaml`).
- **No Terraform.** The manual Layer-0 foundation (OS + RKE2 + cert-manager + Rancher + Cloudflare
  tunnel) is `helm` + `kubectl` + documented steps ([`docs/manual-setup.md`](../../docs/manual-setup.md)).

## Platform services (on mgmt-01)

- `cattle-system` — **Rancher** + cert-manager (manual foundation, not deployed by this repo).
- `cloudflared` — in-cluster tunnel connector → `*.cellarwood.org` + remote SSH/kubectl.
- `object-store` — **Garage** (EU, Rust, S3-compatible): backups + Thanos + Loki, one store.
- `cattle-resources-system` — **rancher-backup** operator + nightly `Backup` CR → Garage S3.
- `cattle-monitoring-system` — **kube-prometheus-stack** (Prometheus + Grafana + Thanos → Garage).
- `cattle-logging-system` — **Loki** (central logs → Garage).
- `registry-cache` — pull-through Docker registry mirror (LAN image cache).
- Downstream clusters — a light Prometheus observability agent (`cluster/downstream/observability-agent`).

> **mgmt-01 hosts no first-party apps or agents** — no FastAPI services, no web frontends. It is the
> fleet's control-plane + observability/backup/registry hub. If a change looks like business-app
> code, it's in the wrong repo.

## Versions

- Chart/image versions are marked **`# [verify]`** / `__REPLACE__` in each `Chart.yaml` dependency and
  `values.yaml` — confirm against upstream and **pin a real version before deploying**. No `:latest`.
  Match the Rancher `2.14.x` line for `rancher-*` charts.

## Tooling (workstation)

- `kubectl` (RKE2-compatible client); `helm` v3.20+; the `helm-secrets` plugin
  (`helm plugin install https://github.com/jkroepke/helm-secrets`).
- `sops`, `age` — secret encryption (`brew install sops age`); `scripts/secrets.py` wraps them.
- `cloudflared` — remote SSH context + the remote kubectl forwarder (`brew install cloudflared`).
- `ssh` — key authorised on the node; Rancher UI for fleet management.

## Broader conventions (for code added to this repo)

### Python (default for scripts)

- Use `uv` exclusively for any non-trivial app — NEVER `pip` directly. For a single stdlib script
  (like `scripts/secrets.py`) a plain `#!/usr/bin/env python3` is fine.
- Type hints required (Python 3.10+ syntax).

### Scripts & automation

- Default: Python for non-trivial scripts. Shell only for trivial one-liners (or Makefile glue).
  Never PowerShell.

### Containers & deployment

- Pin image tags in each chart's `values.yaml` — no `latest`. Plain Helm v3 (`helm upgrade --install`)
  for release management.
