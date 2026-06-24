# WORKFLOW — MANDATORY FOR ANY PROMPT THAT RESULTS IN CHANGES

**If you are going to use the Edit or Write tool, or run any cluster-mutating `helm` / `kubectl` / SSH command, you MUST complete the workflow in `rules/` before reporting completion.** Applies to every type of work — Helm chart/values tweaks, new secrets, tunnel/DNS changes, downstream-agent rollouts, host-side config. No exceptions.

Steps, in order (each phase's detailed procedure is in the correspondingly-numbered `rules/` file — already loaded into context, no need to open it):

1. **Understand** → [`rules/02-understand.md`](rules/02-understand.md)
2. **Plan** → [`rules/03-plan.md`](rules/03-plan.md) *(skip for trivial changes)*
3. **Implement** → [`rules/05-implement.md`](rules/05-implement.md)
4. **Test** → [`rules/06-testing.md`](rules/06-testing.md)
5. **Report** → [`rules/08-report.md`](rules/08-report.md)

Reference files: [`rules/01-project-config.md`](rules/01-project-config.md) (cluster + access), [`rules/09-code-quality.md`](rules/09-code-quality.md), [`rules/10-tech-stack.md`](rules/10-tech-stack.md), [`rules/11-communication.md`](rules/11-communication.md).

**NEVER report completion without first verifying the resulting cluster state (or, for scripts, a successful run).** If you `helm upgrade --install` and stop without checking `kubectl rollout status` and a probe, you have failed. Verification is YOUR responsibility — the user should never need to ask you to test.

**Trivial changes** (typo in a values comment, README tweak, indentation fix that doesn't change rendered output): skip step 2. State what you'll do and proceed.

## Cluster at a glance

- `mgmt-01` · the **Rancher control plane** of the NUC fleet · NUC Core 3 N355 / 16 GB · openSUSE Leap Micro (immutable, SELinux per Runbook) · **RKE2** single node.
- Runs **Rancher** itself (`cattle-system`) + cert-manager; spare capacity is the fleet's **observability + backup + registry hub** (Garage S3, kube-prometheus-stack + Thanos, Loki, rancher-backup, registry-cache).
- Public edge `*.cellarwood.org` via in-cluster `cloudflared` (dashboard-managed token tunnel) → **ClusterIP Services**; **no in-cluster ingress controller**.
- Deployed with **plain Helm** (`make deploy` = `helm upgrade --install` per chart under `cluster/`); manual Layer-0 foundation in [`docs/manual-setup.md`](../docs/manual-setup.md). **No Helmfile, no Terraform.**
- Full cluster facts — access, edge, object store, day-2 → [`rules/01-project-config.md`](rules/01-project-config.md); stack & conventions → [`rules/10-tech-stack.md`](rules/10-tech-stack.md).

## This box IS the control plane — read before you touch anything

`mgmt-01` runs Rancher, which manages every downstream cluster in the fleet. A bad change here
doesn't take down one app — it can destabilize fleet management. Two consequences:

- **Never mutate a downstream cluster's own workloads from this repo.** The only cross-cluster
  action this repo performs is pushing the read-only-ish **observability agent** via
  `make deploy-downstream c=<context>`. Everything else in this repo targets the local `mgmt-01` cluster.
- **Treat Rancher/`cattle-*` state as off-limits** unless the manifest lives in this repo
  (rancher-backup, monitoring, logging are ours; Rancher core itself is the manual foundation).

## Access — LOCAL vs REMOTE (read this before reporting the node "unreachable")

This node has **two access paths**, and a tool failure on one is **not** an outage. The **LAN path**
only works from the home LAN; **off-LAN it fails immediately** (`Network is unreachable` /
`Connection refused` / TCP timeout) — that does **not** mean the cluster is down. **Always try the
remote path (cloudflared forwarder) before reporting the node or cluster unavailable; only report it
down if BOTH fail.** Contexts, hostnames (`ssh.cellarwood.org`, `k8s.cellarwood.org`), and the
forwarder command are in [`rules/01-project-config.md`](rules/01-project-config.md) § Server & access
and [`docs/remote-access.md`](../docs/remote-access.md).

## Standing authorizations — do NOT ask before doing these

These are pre-approved against the **`mgmt-01`** (local) cluster. Run them yourself when the
situation calls for it. **Always verify `kubectl config current-context` resolves to `mgmt-01` (or
pass `--kube-context mgmt-01`) before any mutation** — the workstation kubeconfig also holds the
downstream clusters.

### Read-only inspection (always safe)

- Any `kubectl get / describe / logs / top / explain / api-resources` — across any namespace on `mgmt-01`.
- `helm template ./cluster/<tier>/<chart>`, `helm lint`, `helm diff upgrade` — pure local rendering or read-only.
- Any `helm list / status / get values / get manifest / history` against installed releases.
- `kubectl --dry-run=server` / `--dry-run=client` to validate manifests.
- `./scripts/secrets.py view <path>` / `./scripts/secrets.py lint` — read-only secret inspection.
- `curl` / `wget` probes against in-cluster Services and public `https://*.cellarwood.org` URLs.
- `ssh mgmt-01` (remote via Cloudflare Access) for **read-only** host inspection: `systemctl status rke2-server`, `journalctl -u rke2-server`, `ip -br a`, `ss -tlnp`, `getenforce`, config reads under `/etc/rancher/`.
- Read-only Rancher inspection via the UI (`rancher.cellarwood.org`) or `kubectl -n cattle-system`.

### Pre-approved mutations against `mgmt-01`

Scoped to charts/secrets whose definitions live in **this repo** (`cluster/`, the co-located
`*.enc.yaml`). You may run these without asking:

- `helm upgrade --install <release> ./cluster/<tier>/<chart> -n <ns>` (= `make deploy`) for charts in this repo. Follow with `kubectl rollout status`.
- `helm rollback <release> <rev> -n <ns>` to revert a release this repo manages.
- `kubectl rollout restart deployment/<name> -n <ns>` (or `statefulset/<name>`) for workloads managed by this repo's releases.
- `kubectl delete pod <name> -n <ns>` to force-recycle a single pod.
- `make secrets-apply` / `./scripts/secrets.py apply <path>` to apply this repo's out-of-band secrets.
- `kubectl create namespace <ns> --dry-run=client -o yaml | kubectl apply -f -` for namespaces this repo's secrets/releases need.

### Requires confirmation — always ask first

- `helm uninstall` / removing a chart's release (may delete PVCs / Garage data).
- `kubectl delete namespace` — never without explicit confirmation.
- `kubectl delete <kind>` for resources not owned by this repo's releases — **including anything in `cattle-system` (Rancher core), `kube-system`, or `cloudflared`** unless that manifest lives in this repo.
- Any mutation on a context other than `mgmt-01` — **including pushing to a downstream cluster** beyond the agreed `make deploy-downstream` observability agent.
- Changing the **edge/ingress strategy** (introducing an in-cluster ingress controller, NodePorts) — touches the tunnel model and RKE2/host state.
- Mutating SSH commands on the node — `systemctl restart/start/stop`, edits under `/etc/rancher/`, `transactional-update pkg …`, reboots. (Immutable OS — host changes go via `transactional-update` + reboot, not `zypper` into the running system.)
- Editing the `cloudflared` tunnel token overlay, or Cloudflare-side tunnel/Access/DNS config.
- Garage day-2 that changes cluster layout or destroys data (`garage layout`, `bucket`/`key` deletes).
- `git push`, `git push --force`, branch deletes — **never commit unless the user explicitly asks** (see global instruction).
- Anything touching secrets, TLS material, tokens, SOPS/age private keys, or `kubeconfig` files. (Secrets standard: [`docs/secrets.md`](../docs/secrets.md) — SOPS+age, applied via `scripts/secrets.py`.)

When in doubt: ask. This box is the fleet's Rancher control plane — a bad apply destabilizes the management of every downstream cluster, not just one service.
