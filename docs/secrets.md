# Secrets

How every secret in this repo — tokens, S3 keys, encryption keys, the tunnel token — is stored,
committed, deployed, and rotated. **This is the fleet standard** (identical scheme in `home-lab-01`
and the other fleet repos). One rule above all others:

> **No plaintext secret is ever committed, and no secret is ever created imperatively from a
> remembered one-liner. Every secret is SOPS+age-encrypted, committed, versioned, and rotatable.**

## Why this design (and why not Vault)

Kubernetes Secrets are only **base64**, not encrypted — so the exposure we actually care about is:
*don't leak plaintext into git, and encrypt what lands in etcd.* We get defense in depth from three
layers, none of which is a service we have to babysit:

1. **In git — SOPS + age.** Secrets are encrypted with [SOPS](https://github.com/getsops/sops) to
   [age](https://github.com/FiloSottile/age) recipients *before* they touch a commit. The committed
   ciphertext is safe to push; only a holder of an age private key can decrypt.
2. **In etcd — RKE2 encryption-at-rest.** RKE2 enables Secret encryption-at-rest by default, so the
   base64 Secret is stored encrypted on disk (verify per the checklist below).
3. **In the cluster — RBAC.** Only the admin kubeconfig can read Secrets (single-admin cluster).

**We deliberately do _not_ run HashiCorp Vault.** It must be unsealed on every restart, and this
node runs an auto-patching, auto-rebooting immutable OS (Leap Micro `transactional-update.timer` +
`rebootmgr`) — Vault would seal on every reboot and silently break secret delivery until someone
SSHed in to unseal it. Vault's usual Kubernetes bridge (External Secrets Operator) also still
materializes a base64 k8s Secret, so it wouldn't even remove the concern that motivates it. Vault
earns its complexity at a scale `mgmt-01` doesn't have. If we ever reach that scale, adding Vault is
a clean additive step — this design doesn't block it.

## The keys

Two age **recipients** (public keys). The matching **private** keys never live in the repo.

| Recipient (public key)                                              | Role            | Private key lives… |
|--------------------------------------------------------------------|-----------------|--------------------|
| `age1fgfwws7708s2xk0m99ftrajd98py9r62qnldvkklvs4tx5knz3zs4rjnud`    | fleet/workstation | `~/.config/sops/age/keys.txt` (every operator workstation, fleet-wide) |
| `age1mpng9vq3ae3ek6c4l0tes05s8um8yv3lg6j7a2xdwy786vrzap8s4w6hg6`    | break-glass     | **offline** (password manager / hardware token) — recovery only, never beside the fleet key |

These are the **same two fleet recipients** used across the fleet, so the one private key already on
your workstation decrypts both `mgmt-01` and the downstream repos — no per-repo key. Both keys can
decrypt **every** secret, so losing the workstation key never locks the fleet out: recover with
break-glass, then rotate (below). Recipients are declared once in the root [`.sops.yaml`](../.sops.yaml);
SOPS walks up to it from any file's directory, so **do not** add per-file `.sops.yaml` overrides —
they would silently shadow these recipients.

## Two file shapes

Secrets are **co-located** with the chart that consumes them:
`cluster/<tier>/<chart>/<name>.enc.yaml`. The commit points at the chart, not a separate directory.

**A. Out-of-band Kubernetes Secret manifests** — a real `kind: Secret`; SOPS encrypts only the values
under `data`/`stringData` (`encrypted_regex` in the root `.sops.yaml`), so `apiVersion/kind/metadata`
stay readable and diffs are meaningful. Applied **out of band** with `./scripts/secrets.py apply`
(= `sops -d | kubectl apply -f -`) so **Helm never owns them** — a `helm upgrade` can't clobber a
live value. Charts reference them by name (`existingSecret` / `envFrom` / `credentialSecretName`), so
chart config doesn't change. Example: `cluster/infra/garage/garage-secrets.enc.yaml`.

**B. helm-secrets values overlay** — where a secret must be a Helm *template input* rather than a k8s
Secret manifest (today: only the cloudflared tunnel token,
`cluster/infra/cloudflared/secrets.enc.yaml`). The **whole file** is encrypted; the chart renders the
token into a Secret, and Helm decrypts the overlay **in-line at deploy** via the
[`helm-secrets`](https://github.com/jkroepke/helm-secrets) plugin:
`helm upgrade --install cloudflared ./cluster/infra/cloudflared -n cloudflared -f secrets://cluster/infra/cloudflared/secrets.enc.yaml`.
It is **not** applied with `secrets.py apply`.

Both shapes end in `.enc.yaml` and are matched by the root `.sops.yaml` (the cloudflared rule comes
**first** so the overlay gets whole-file encryption, not the `data`/`stringData`-only rule). Any
plaintext placeholders end in `.example.yaml` and are **never** encrypted (they hold no real values).

## Tooling

```bash
brew install sops age helm            # one-time
helm plugin install https://github.com/jkroepke/helm-secrets   # for the cloudflared overlay
```

Your age key (the fleet key — create once if you don't already have it from another fleet repo; the
**public** line is what's already in `.sops.yaml`):

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt   # new key (only if you have none)
age-keygen -y ~/.config/sops/age/keys.txt   # print the public recipient of an existing key
```

macOS `sops` otherwise defaults to `~/Library/Application Support/sops/age/keys.txt`;
[`scripts/secrets.py`](../scripts/secrets.py) exports `SOPS_AGE_KEY_FILE` to the XDG path so
encrypt/decrypt is OS-agnostic and matches the fleet convention.

## Everyday workflow — `scripts/secrets.py`

One tool wraps `sops` + `kubectl` and guards against the wrong cluster (only a `mgmt-01[-remote]`
context is accepted — override with `SECRETS_KUBE_CONTEXT`). Run it from the repo root. The
`make` secret targets delegate to it.

```bash
# Author a NEW out-of-band secret: write a plaintext kind: Secret next to its chart, then encrypt:
$EDITOR cluster/platform/foo/foo.enc.yaml               # plaintext stringData: { ... }
./scripts/secrets.py encrypt cluster/platform/foo/foo.enc.yaml

# Migrate an existing live Secret into git (zero downtime — captures exactly what's running):
./scripts/secrets.py pull object-store garage-secrets cluster/infra/garage/garage-secrets.enc.yaml

# Change a value later (decrypts to a temp file, re-encrypts on save):
./scripts/secrets.py edit  cluster/infra/garage/garage-secrets.enc.yaml

# Deploy the out-of-band secret to the cluster (sops -d | kubectl apply):
./scripts/secrets.py apply cluster/infra/garage/garage-secrets.enc.yaml   # (or: make secrets-apply for all)

# Inspect without applying:
./scripts/secrets.py view  cluster/infra/garage/garage-secrets.enc.yaml

# After changing recipients in .sops.yaml — re-encrypt everything to the new key set:
./scripts/secrets.py rekey

# CI / pre-commit hygiene — fail if any *.enc.yaml is plaintext or stray decrypted files exist:
./scripts/secrets.py lint                                        # (or: make secrets-lint)
```

The cloudflared **tunnel token** (shape B) is edited with `sops` directly — it is **not** applied
with `secrets.py` (Helm decrypts it at deploy):

```bash
sops cluster/infra/cloudflared/secrets.enc.yaml    # paste the token under tunnel.token → saved encrypted
```

## Deploying — secrets first, then the chart

Out-of-band secrets are applied **before** the chart that consumes them; the cloudflared overlay
rides along with its release. See [`bootstrap.md`](./bootstrap.md) for the full wave ordering.

```bash
make namespaces           # kubectl apply -f bootstrap/namespaces.yaml
make secrets-apply        # applies every out-of-band *.enc.yaml
make deploy               # helm upgrade --install each chart; cloudflared decrypts its overlay in-line
```

## Secret inventory

**A. Out-of-band Secrets** (co-located → `make secrets-apply`). *Wave 1* can be created up front;
*Wave 2* uses the Garage S3 key, imported when Garage is initialised ([`bootstrap.md`](./bootstrap.md) §3).

| Secret | Co-located in | Namespace | Wave |
|--------|---------------|-----------|------|
| `garage-secrets`     | `cluster/infra/garage/`            | `object-store`             | 1 |
| `backup-encryption`  | `cluster/platform/rancher-backup/` | `cattle-resources-system`  | 1 |
| `garage-s3-creds`    | `cluster/platform/rancher-backup/` | `cattle-resources-system`  | 2 |
| `thanos-objstore`    | `cluster/platform/monitoring/`     | `cattle-monitoring-system` | 2 |
| `loki-s3-creds`      | `cluster/platform/logging/`        | `cattle-logging-system`    | 2 |

**B. helm-secrets values overlay** (decrypted in-line at deploy by `helm-secrets`).

| File | Release | Holds |
|------|---------|-------|
| `cluster/infra/cloudflared/secrets.enc.yaml` | `cloudflared` | `tunnel.token` (Cloudflare dashboard tunnel token) |

> The Wave-2 S3 secrets share one Garage app key. When you rotate the Garage key, rotate all three
> together.

## Rotation & recovery

- **Rotate a secret value:** `secrets.py edit <file>` → change the value → `secrets.py apply <file>`
  → `kubectl rollout restart` the consuming workload → commit the updated ciphertext. (The cloudflared
  token: `sops cluster/infra/cloudflared/secrets.enc.yaml` → `make deploy` → commit.)
- **Onboard a new operator / machine:** they generate an age key, you add its **public** line to the
  `age:` recipients in `.sops.yaml`, run `secrets.py rekey`, and commit. They can now decrypt.
- **Off-board / compromised workstation key:** remove that recipient from `.sops.yaml`, `rekey`, commit
  — **and** rotate the underlying secret *values* (the old key could have read the old ciphertext from
  git history). Use the break-glass key to decrypt if the removed key was the only working one.
- **Break-glass:** the offline key decrypts everything. Use it only to recover when the fleet key is
  lost, then immediately mint a new fleet key, re-add it, `rekey`, and rotate values.

## Verify the posture (checklist)

- [ ] `./scripts/secrets.py lint` passes (no plaintext `*.enc.yaml`, no stray `*.dec.yaml`/`*.plain.yaml`).
- [ ] `git grep -nE '(password|token|secret|api[_-]?key|access[_-]?key):\s*\S' -- '*.yaml' ':!*.enc.yaml' ':!*.example.yaml'`
      finds nothing real.
- [ ] `sops -d <file>` round-trips for every `*.enc.yaml`.
- [ ] `cluster/infra/cloudflared/secrets.enc.yaml` resolves to the **whole-file** rule in
      `.sops.yaml` (no `encrypted_regex`) — so the cloudflared token is fully encrypted, not left plaintext.
- [ ] etcd encryption-at-rest is on (operator, needs root — no passwordless sudo on these nodes):
      `ssh mgmt-01 'sudo rke2 secrets-encrypt status'` → `Encryption Status: Enabled`.
