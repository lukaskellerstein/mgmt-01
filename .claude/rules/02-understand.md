# Step 1: Understand

- Read the relevant chart (`cluster/<tier>/<chart>/` — `Chart.yaml`, `values.yaml`, `templates/`),
  co-located secret files, or docs and identify impacted resources (which chart/release, which
  namespace, which Service — or `cluster/downstream/observability-agent` for a downstream change).
- Ask clarifying questions if requirements are ambiguous (e.g. "is this a local-cluster chart or a
  downstream agent change?", "public via the tunnel or cluster-internal only?"). Secrets are always
  SOPS+age (see [`docs/secrets.md`](../../docs/secrets.md)) — never ask "Vault or imperative".
- Identify gaps and improvements (missing resource limits, a `__REPLACE__`/`# [verify]` version still
  unpinned, hardcoded values that belong in a chart's `values.yaml`, secrets in the wrong place).
- Understand the requirement completely before proceeding. Remember this box **is** the Rancher
  control plane — a careless change can destabilize fleet management, not just one app.
- **For bug reports / incidents on the cluster** — first verify you can reach it and which path
  you're on (see [`01-project-config.md`](01-project-config.md) § Server & access):
  `kubectl config current-context` should be `mgmt-01` (or your renamed/forwarded equivalent). **If
  probes fail with `Network is unreachable` / timeout, you are likely off-LAN — bring up the
  cloudflared forwarder (`cloudflared access tcp --hostname k8s.cellarwood.org --url 127.0.0.1:6443`)
  before concluding the cluster is down.** Then reproduce. Cheapest probes (details in
  [`06-testing.md`](06-testing.md) § 4d):
  - `kubectl get pods,svc -A` · `describe` · `logs`
  - Rancher health: `kubectl -n cattle-system get pods,deploy` and the `rancher.cellarwood.org` edge probe
  - in-cluster `cloudflared` log check (`kubectl -n cloudflared logs deploy/... | grep "Registered tunnel connection"`)
  - object store / observability: `kubectl -n object-store get pods` · `kubectl -n cattle-monitoring-system get pods`
