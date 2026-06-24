# Bootstrap & Day-2 — mgmt-01

Plain-Helm deploy + one-time initialisation that can't be declarative. The manual foundation
below this (OS, RKE2, cert-manager, Rancher, Cloudflare tunnel) lives in
[`manual-setup.md`](./manual-setup.md) — do that first.

## 0. Prereqs
[`manual-setup.md`](./manual-setup.md) complete: Leap Micro + RKE2 + cert-manager + Rancher +
`agent-tls-mode=system-store` + Cloudflare tunnel created. `kubectl` against `mgmt-01` works.
Tools: `sops`, `age`, `helm`, and the `helm-secrets` plugin
(`brew install sops age helm && helm plugin install https://github.com/jkroepke/helm-secrets`).

## 1. Secrets — SOPS + age (nothing plaintext in Git)
**Full scheme, keys, tooling and rotation: [`secrets.md`](./secrets.md).** Secrets are co-located
with their chart (`cluster/<tier>/<chart>/<name>.enc.yaml`), SOPS-encrypted, and committed. Your
existing fleet age key (`~/.config/sops/age/keys.txt`) decrypts — the recipients are already in
`.sops.yaml`, no per-repo key to generate. The out-of-band Secrets are applied with
`make secrets-apply` (delegates to `scripts/secrets.py`) so Helm never owns them.

**The Wave-1 and Wave-2 Secret *values* are already generated and committed** (random RPC/admin
tokens, the backup AES-CBC key, and a Garage S3 app key). You don't author them — just apply. Review
any value with `./scripts/secrets.py view <file>`; rotate per [`secrets.md`](./secrets.md).

The **one** secret you must supply is the cloudflared **tunnel token** — it's issued by Cloudflare
(`manual-setup.md` §5) and can't be generated. It's a helm-secrets values overlay; set it once:
```bash
sops cluster/infra/cloudflared/secrets.enc.yaml    # paste the token under tunnel.token → saved encrypted
```

## 2. Namespaces, secrets, then deploy
```bash
make namespaces                          # kubectl apply -f bootstrap/namespaces.yaml
make secrets-apply                       # applies every out-of-band *.enc.yaml (Wave 1 + Wave 2)
# pin every "__REPLACE__" chart version (Chart.yaml dependencies) first   # [verify]
make deploy                              # helm upgrade --install each chart, in order
```
`make deploy` brings up Garage, monitoring, logging, registry-cache and rancher-backup, then
cloudflared last (which fails until the §1 token is set). Garage's S3 consumers stay pending until
the bucket/key are created in §3.

## 3. Initialise Garage (one-time, after the pod is Running)
Garage needs its cluster layout assigned, buckets created, and **the pre-generated S3 app key
imported** (so it matches the committed Wave-2 Secrets — `garage-s3-creds`, `thanos-objstore`,
`loki-s3-creds`, which all share one key). Read the committed key, then import it:
```bash
G="kubectl -n object-store exec -it garage-0 -- /garage"
$G status                                   # note the node ID
$G layout assign -z dc1 -c 180G <node-id>   # [verify] capacity ≤ PVC
$G layout apply --version 1

# buckets
for b in rancher-backup thanos loki backups; do $G bucket create $b; done

# Import the SAME key the committed Wave-2 secrets use (don't `key create` a fresh random one).
# `garage key import` takes the access-key-id and secret-key as POSITIONAL args (Garage v1.0.1):
#   garage key import [--yes] -n <name> <key-id> <secret-key>
AK=$(./scripts/secrets.py view cluster/platform/rancher-backup/garage-s3-creds.enc.yaml | awk '/accessKey:/{print $2}' | tr -d '"')
SK=$(./scripts/secrets.py view cluster/platform/rancher-backup/garage-s3-creds.enc.yaml | awk '/secretKey:/{print $2}' | tr -d '"')
$G key import --yes -n mgmt-rw "$AK" "$SK"
for b in rancher-backup thanos loki backups; do
  $G bucket allow --read --write --key "$AK" $b
done
```
The Wave-2 Secrets are already applied (step 2), so rancher-backup, the Thanos sidecar, and Loki
now have working S3 creds — restart/let them re-sync if they came up before the bucket existed
(`kubectl -n cattle-monitoring-system rollout restart statefulset ...`).

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
