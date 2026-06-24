# Step 3: Implement

Write clean IaC from the start. Follow these rules during implementation:

- Do NOT commit via `git` unless explicitly instructed by the user.
- When creating diagrams or graphs, use `mermaid`.
- Refactor continuously — extract repeated values into a chart's `values.yaml` the moment you see duplication.
- Remove dead code — unused values keys, commented-out manifest blocks, abandoned charts.
- After editing a chart/values: re-render with `helm template ./cluster/<tier>/<chart>` and skim before applying.
- After editing `scripts/secrets.py`: run its `--help` / a `lint` before declaring done.

## Local Helm charts (`cluster/<infra|platform>/<chart>`)

One local chart per platform component. Deploy via `helm upgrade --install <release> ./cluster/<tier>/<chart> -n <ns>`
(`make deploy`); preview via `helm template` / `helm diff upgrade`.

- **Chart shape** — `Chart.yaml` + `values.yaml` (+ `templates/`). Upstream charts are **thin
  wrappers**: a `dependencies:` entry in `Chart.yaml`, overrides keyed under the dependency name in
  `values.yaml`; run `helm dependency build` first. Deploy order matters (Garage before
  Thanos/Loki/rancher-backup) — apply charts in dependency order.
- **Pin every version.** Replace `__REPLACE__` / `# [verify]` with a real, upstream-confirmed
  version in `Chart.yaml`/`values.yaml` before deploying. No `:latest` image tags.
- **First-party charts** (Garage, cloudflared, the rancher-backup `Backup` CR) carry their own
  `templates/` — don't reach for a generic raw-manifest wrapper.
- Resource requests/limits are **mandatory** for every container we own — `mgmt-01` is a 16 GB box.
- For upstream charts: override via the wrapper's `values.yaml`, never fork the chart's templates.
- **Downstream agent** — the observability agent for workload clusters lives in
  `cluster/downstream/observability-agent`; apply it once per cluster: `make deploy-downstream c=<kube-context>`
  (Helm is single-cluster per run). Never reconfigure a downstream's own workloads from this repo.

## Edge / public exposure

- The in-cluster `cloudflared` (namespace `cloudflared`, **dashboard-managed token**) terminates
  `*.cellarwood.org` and routes each public hostname to an **in-cluster Service**. To expose a new
  HTTP service publicly: add a public-hostname route on the `mgmt-01` tunnel (Cloudflare Zero Trust
  dashboard) → `http://<svc>.<ns>.svc.cluster.local:<port>`. **No `IngressRoute`/`Ingress`, no
  NodePorts, no inbound firewall changes.** TCP services (SSH, kube-API) use TCP public hostnames +
  Cloudflare Access — see [`docs/remote-access.md`](../../docs/remote-access.md).
- Editing the tunnel token overlay or Cloudflare-side config requires confirmation (see `CLAUDE.md`).

## Secrets

**Full strategy: [`../../docs/secrets.md`](../../docs/secrets.md). SOPS+age is the standard — never imperative, never Vault.**

- **Never** commit plaintext secrets. The committed form is a SOPS+age-encrypted file `*.enc.yaml`.
  Plaintext (`*.dec.yaml`, `*.plain.yaml`, `age/keys.txt`, `keys.txt`) is gitignored.
- Secrets are **co-located** with their chart (`cluster/<tier>/<chart>/<name>.enc.yaml`). Two shapes:
  - **Out-of-band k8s Secret** (only `data`/`stringData` encrypted), applied with
    `./scripts/secrets.py apply <path>` (= `sops -d | kubectl apply`). Helm never owns these; charts
    reference them by name (`existingSecret` / `envFrom` / `credentialSecretName`).
  - **helm-secrets values overlay** — `cluster/infra/cloudflared/secrets.enc.yaml` (whole file
    encrypted, today just the cloudflared `tunnel.token`). Helm decrypts it in-line at deploy
    (`-f secrets://...`) and the chart renders it into a Secret; **not** applied with `secrets.py apply`.
- **Do not** create secrets imperatively with `kubectl create secret`. Author a new one as a plaintext
  manifest next to its chart, then `./scripts/secrets.py encrypt <path>` (or `make sops-edit`).
  Migrate a live one with `./scripts/secrets.py pull <ns> <name> <path>`.
- Recipients (fleet/workstation + offline break-glass) live in the root `.sops.yaml`; never add a
  per-file `.sops.yaml`. After changing recipients, `./scripts/secrets.py rekey`.
- The real values live only in `*.enc.yaml`; any `*.example.yaml` placeholder is documentation only.

## Repository structure

```
mgmt-01/
├── README.md
├── .claude/                # how Claude Code works here (workflow + rules + settings)
├── bootstrap/namespaces.yaml   # declarative namespaces (apply first)
├── cluster/
│   ├── infra/              # cloudflared, garage, registry-cache  (+ co-located *.enc.yaml)
│   ├── platform/           # monitoring, logging, rancher-backup  (+ co-located *.enc.yaml)
│   └── downstream/         # observability-agent (push to workload clusters)
├── Makefile                # deploy + secret workflow (delegates to scripts/secrets.py)
├── scripts/                # automation — scripts/secrets.py (SOPS workflow)
└── docs/                   # manual-setup, bootstrap, secrets, remote-access
```
Each chart dir is a local Helm chart (`Chart.yaml` + `values.yaml` [+ `templates/`]); upstream charts
are thin wrappers via a `dependencies:` entry. Secrets are co-located `*.enc.yaml`.
