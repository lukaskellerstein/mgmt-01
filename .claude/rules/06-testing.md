# Step 4: Testing

**Every change must be verified before reporting completion. No exceptions.**

## 4a. Define your Definition of Done

Before testing, **write out your DoD checklist in the conversation** so the user can see what you
intend to verify. Example for a chart change:

> **Definition of Done for "add Loki S3 retention":**
> - [ ] `helm lint ./cluster/platform/logging` / `helm template ./cluster/platform/logging` render cleanly (limits set; version pinned)
> - [ ] `helm diff upgrade loki ./cluster/platform/logging -n cattle-logging-system` shows exactly the intended change
> - [ ] `helm upgrade --install loki ./cluster/platform/logging -n cattle-logging-system` + `kubectl rollout status` succeeds within timeout
> - [ ] In-cluster probe / Grafana shows Loki healthy; Thanos/Loki still shipping to Garage

Example for a secret change:

> **Definition of Done for "rotate garage-s3-creds":**
> - [ ] `./scripts/secrets.py edit cluster/platform/rancher-backup/garage-s3-creds.enc.yaml` re-encrypts cleanly
> - [ ] `./scripts/secrets.py lint` passes (no plaintext, no stray decrypted files)
> - [ ] `./scripts/secrets.py apply cluster/platform/rancher-backup/garage-s3-creds.enc.yaml` + `rollout restart` consumers

## 4b. Cluster changes — test in order, cheapest first

### 1. Static lint and render (no cluster contact)

```bash
helm dependency build ./cluster/<tier>/<chart>     # wrapper charts only
helm lint     ./cluster/<tier>/<chart>
helm template ./cluster/<tier>/<chart> -n <ns> | less
```

Look for: unresolved values (`<no value>`), missing labels, an unpinned `__REPLACE__` / `# [verify]`
version, missing resource limits, secrets rendered with real values.

### 2. Confirm context (and reachability — see [`01`](01-project-config.md) § Server & access)

```bash
kubectl config current-context   # MUST resolve to mgmt-01 (renamed/forwarded equivalent)
```

If not, fix it or pass `--kube-context mgmt-01`. **If you're off-LAN**, bring up the forwarder
(`cloudflared access tcp --hostname k8s.cellarwood.org --url 127.0.0.1:6443`). **Never** deploy to a
downstream cluster by accident — `helm upgrade` here targets the local (`mgmt-01`) cluster; the
downstream agent goes through `make deploy-downstream c=<context>` only.

### 3. Preview the plan

```bash
helm diff upgrade <release> ./cluster/<tier>/<chart> -n <ns>   # helm-diff plugin
```

### 4. Apply

```bash
helm upgrade --install <release> ./cluster/<tier>/<chart> -n <ns>   # (make deploy for all)
```

Namespaces + out-of-band secrets first when relevant: `make namespaces && make secrets-apply`
(Helm does not own them).

### 5. Wait for ready

```bash
kubectl rollout status deploy/<name> -n <ns> --timeout=120s   # or statefulset/<name>
kubectl -n <ns> get pod,svc
```

A `Running` pod is not a healthy pod. Check `READY` and recent restart counts.

### 6. Smoke test the actual behaviour

**Inside the cluster** (hit the target Service directly):

```bash
kubectl run probe --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://<svc>.<ns>.svc:<port>/
```

**Through the tunnel** (full edge path, only after the in-cluster probe succeeds):

```bash
curl -fsS https://rancher.cellarwood.org/ -o /dev/null -w '%{http_code}\n'
curl -fsS https://grafana.cellarwood.org/ -o /dev/null -w '%{http_code}\n'
```

## 4c. Secret / script changes — local verification

```bash
python3 -c "import ast,sys; ast.parse(open('scripts/secrets.py').read())"   # syntax
./scripts/secrets.py lint        # no plaintext *.enc.yaml, no stray *.dec.yaml/*.plain.yaml
./scripts/secrets.py view cluster/<tier>/<chart>/<name>.enc.yaml  # round-trips (decrypts) a given file
```

## 4d. Diagnostics — when something is wrong

```bash
# Cluster events / pod / logs
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail -20
kubectl -n <ns> describe pod/<name>
kubectl -n <ns> logs deploy/<name> --tail=200

# Helm release state
helm list -A && helm status <release> -n <ns>

# Rancher control plane
kubectl -n cattle-system get pods,deploy
curl -fsS https://rancher.cellarwood.org/ -o /dev/null -w '%{http_code}\n'

# cloudflared (IN-CLUSTER, not host systemd)
kubectl -n cloudflared get pods
kubectl -n cloudflared logs deploy/cloudflared --tail=100   # look for "Registered tunnel connection"

# Object store / observability
kubectl -n object-store get pods            # garage Running; `exec ... /garage bucket list`
kubectl -n cattle-monitoring-system get pods
kubectl -n cattle-logging-system get pods
kubectl -n cattle-resources-system get backups

# Host / OS (read-only)
ssh mgmt-01 'systemctl status rke2-server; journalctl -u rke2-server --no-pager -n 100; getenforce'
```

Mutating cloudflared (token/Cloudflare config), Rancher state not owned by this repo, or anything
host-side requires explicit user confirmation — see `CLAUDE.md` § Standing authorizations.

## 4e. Non-testable changes

If a change is purely documentary (README, comments, gitignore tweaks): explicitly state why no
cluster test is needed. Run `helm template ./cluster/<tier>/<chart>` anyway to confirm the rendered
output is unchanged.

## 4f. Fix and repeat

If a test fails: read the error, fix the chart/values/script, re-lint, re-render, re-diff,
re-apply. Repeat until DoD passes. If you roll forward more than twice without progress,
`helm rollback <release> <rev> -n <ns>` and step back to understand.
