# Bootstrap & Day-2 — mgmt-01

GitOps bringup + one-time initialisation that can't be declarative. The manual foundation
below this (OS, RKE2, cert-manager, Rancher, Cloudflare tunnel) lives in
[`manual-setup.md`](./manual-setup.md) — do that first.

## 0. Prereqs
[`manual-setup.md`](./manual-setup.md) complete: Leap Micro + RKE2 + cert-manager + Rancher +
`agent-tls-mode=system-store` + Cloudflare tunnel created. `kubectl` against `mgmt-01` works.

## 1. Secrets — SOPS + age (nothing plaintext in Git)
Encrypted secrets are committed to `secrets/*.enc.yaml`; **Fleet does not decrypt SOPS**, so
they are applied out of band with `make secrets-apply`. Run `make help` for all targets.

```bash
# tools: sops + age must be installed (brew install sops age)
make age-init                       # writes age/keys.txt (back it up offline!), prints recipient
# paste the printed age1... recipient into .sops.yaml (the `age:` line)
```

Create each secret from its template, then encrypt in place:
```bash
for s in garage-secrets tunnel-token backup-encryption; do        # Wave 1 (createable now)
  cp secrets/$s.example.yaml secrets/$s.enc.yaml
  make sops-edit f=$s               # fill values → saved encrypted; git add secrets/$s.enc.yaml
done
```
Wave-1 helpers:
- `garage-secrets`: `openssl rand -hex 32` for each of RPC secret / admin token.
- `backup-encryption`: `head -c 32 /dev/urandom | base64` for the aescbc key.
- `tunnel-token`: the Cloudflare tunnel token from `manual-setup.md` §5.

The **Wave-2** secrets (`garage-s3-creds`, `thanos-objstore`, `loki-s3-creds`) need the
Garage S3 key, which doesn't exist until §3 — fill them there.

Alternatives if you outgrow this: Sealed Secrets (controller decrypts in-cluster, so Fleet
can own the `SealedSecret` CRs) or External Secrets Operator.

## 2. Apply secrets, then hand off to Fleet
```bash
make secrets-apply                       # creates namespaces + applies secrets/*.enc.yaml (idempotent)
kubectl apply -f bootstrap/              # the two Fleet GitRepos → Fleet takes over this repo
```
Fleet now reconciles `fleet/local/*` — Garage, monitoring, logging, registry-cache,
rancher-backup all come up. (Wave-2 consumers stay pending until §3.)

## 3. Initialise Garage (one-time, after the pod is Running)
Garage needs its cluster layout assigned and buckets/keys created.
```bash
G="kubectl -n object-store exec -it garage-0 -- /garage"
$G status                                   # note the node ID
$G layout assign -z dc1 -c 180G <node-id>   # [verify] capacity ≤ PVC
$G layout apply --version 1

# buckets
for b in rancher-backup thanos loki backups; do $G bucket create $b; done

# an app key with rw on all buckets
$G key create fleet-rw                       # prints Key ID + Secret — store in your secret mgr
for b in rancher-backup thanos loki backups; do
  $G bucket allow --read --write --key fleet-rw $b
done
```
Now fill the **Wave-2** secrets with the printed Key ID / Secret, encrypt, and apply:
```bash
for s in garage-s3-creds thanos-objstore loki-s3-creds; do
  cp secrets/$s.example.yaml secrets/$s.enc.yaml
  make sops-edit f=$s               # paste the Garage Key ID / Secret
done
make secrets-apply                  # applies the Wave-2 secrets
```
rancher-backup, the Thanos sidecar, and Loki now have their S3 creds; restart/let them
re-sync. (`kubectl -n cattle-monitoring-system rollout restart statefulset` etc. if needed.)

## 4. Off-site mirror (real DR — single-node Garage is non-durable)
Schedule a sync of the critical buckets to a cheap off-site bucket (EU cloud), e.g. a
CronJob running `rclone sync garage:rancher-backup remote:...`. Don't let mgmt-01 hold the
only copy of its own backups.

## 5. Point fleet nodes at the registry cache (optional)
On each RKE2 node, `/etc/rancher/rke2/registries.yaml`:
```yaml
mirrors:
  docker.io:
    endpoint:
      - "http://registry-cache.<mgmt-01-reachable-host>:5000"   # via tunnel/LAN
```
then `systemctl restart rke2-server` (or `rke2-agent`).

## 6. Verify
- `kubectl -n object-store get pods` → garage Running; `$G bucket list` shows 4 buckets.
- `kubectl -n cattle-resources-system get backups` → rancher-nightly succeeds.
- Grafana (`grafana.cellarwood.org`) shows mgmt-01 metrics; after labelling a downstream
  cluster `observability=agent`, its series appear too.
- `kubectl -n cattle-monitoring-system logs <thanos-sidecar>` → uploading blocks to Garage.
