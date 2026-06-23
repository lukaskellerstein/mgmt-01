# Bootstrap & Day-2 — mgmt-01

Helmfile deploy + one-time initialisation that can't be declarative. The manual foundation
below this (OS, RKE2, cert-manager, Rancher, Cloudflare tunnel) lives in
[`manual-setup.md`](./manual-setup.md) — do that first.

## 0. Prereqs
[`manual-setup.md`](./manual-setup.md) complete: Leap Micro + RKE2 + cert-manager + Rancher +
`agent-tls-mode=system-store` + Cloudflare tunnel created. `kubectl` against `mgmt-01` works.
Tools: `sops`, `age`, `helm`, `helmfile`, and the `helm-secrets` plugin
(`brew install sops age helmfile && helm plugin install https://github.com/jkroepke/helm-secrets`).

## 1. Secrets — SOPS + age (nothing plaintext in Git)
Encrypted secrets are committed to `secrets/*.enc.yaml` and applied out of band with
`make secrets-apply` so Helm never owns them. Run `make help` for all targets.

```bash
make age-init                       # writes age/keys.txt (back it up offline!), prints recipient
# paste the printed age1... recipient into .sops.yaml (the `age:` line)
```

Create each out-of-band `Secret` from its template, then encrypt in place:
```bash
for s in garage-secrets backup-encryption; do        # Wave 1 (createable now)
  cp secrets/$s.example.yaml secrets/$s.enc.yaml
  make sops-edit f=$s               # fill values → saved encrypted; git add secrets/$s.enc.yaml
done
```
Wave-1 helpers:
- `garage-secrets`: `openssl rand -hex 32` for each of RPC secret / admin token.
- `backup-encryption`: `head -c 32 /dev/urandom | base64` for the aescbc key.

The cloudflared **tunnel token** is not a k8s Secret — it's a SOPS Helm values overlay that
Helmfile decrypts in-line (`helm-secrets`). Create it from its example with the token from
`manual-setup.md` §5:
```bash
cp values/secrets/cloudflared-token.example.yaml values/secrets/cloudflared-token.enc.yaml
sops values/secrets/cloudflared-token.enc.yaml    # paste cloudflare.tunnel_token → saved encrypted
```

The **Wave-2** secrets (`garage-s3-creds`, `thanos-objstore`, `loki-s3-creds`) need the
Garage S3 key, which doesn't exist until §3 — fill them there.

## 2. Apply secrets, then deploy with Helmfile
```bash
make secrets-apply                       # creates namespaces + applies secrets/*.enc.yaml (idempotent)
# pin every "__REPLACE__" chart version in helmfile.yaml first   # [verify]
make diff                                # preview the release plan (helmfile diff)
make deploy                              # helmfile sync — installs/upgrades all local releases
```
`helmfile sync` brings up Garage, monitoring, logging, registry-cache and rancher-backup.
(Wave-2 consumers stay pending until §3.)

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
