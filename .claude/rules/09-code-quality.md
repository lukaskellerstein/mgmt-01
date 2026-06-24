# Reference: Code Quality

Write IaC and automation that is **simple, maintainable, and production-ready**. Prioritize clarity over cleverness.

## Universal principles

1. **Simplicity First (KISS)** — prefer a 20-line `values.yaml` that does one thing over a 200-line one with knobs nobody uses.
2. **DRY** — extract repeated values into a chart's `values.yaml`; never inline-duplicate the same config across charts.
3. **YAGNI** — don't add `values.yaml` knobs for cases that don't exist. Add them when the second use lands.
4. **Separation of concerns** — `Chart.yaml` declares *which upstream chart / first-party templates*; `values.yaml` describes *config*; secrets are *SOPS-encrypted* (`*.enc.yaml`, see [`docs/secrets.md`](../../docs/secrets.md)). Don't mix.

## IaC manifest organisation

- Every container we control has `resources.requests` AND `resources.limits` set. No exceptions for "it's small" — mgmt-01 is a 16 GB box; over-commit takes the control plane down.
- Every Deployment/StatefulSet has `livenessProbe` and `readinessProbe` (or a documented reason it can't — upstream charts usually set these).
- Labels follow the recommended Kubernetes label set: `app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/managed-by`.
- Namespace names match the release's purpose; never use `default` for platform workloads. cattle-* namespaces belong to Rancher/charts — only land things there that this repo owns.
- **Idempotency** — `helm upgrade --install` / `secrets.py apply` twice must produce the same cluster state.

## Helm hygiene

- **Pin every chart version.** No `__REPLACE__` and no `# [verify]` placeholders survive into a deploy — confirm against upstream and pin a real version (in `Chart.yaml` dependencies / `values.yaml`) before deploying.
- No `:latest` image tags. Pin in the chart's `values.yaml`.
- First-party charts carry their own `templates/`; upstream charts are thin wrappers via a `dependencies:` entry — don't apply loose YAML out-of-band.
- Keep our config in the wrapper's `values.yaml`, never fork upstream chart templates.

## Secrets

- **Never** commit plaintext secrets. Commit the SOPS+age-encrypted `*.enc.yaml`; apply out-of-band Secrets with `scripts/secrets.py apply`, and let Helm decrypt the helm-secrets values overlay in-line (`-f secrets://...`). See [`docs/secrets.md`](../../docs/secrets.md). No imperative `kubectl create secret`.
- Any `*.example.yaml` lists the required keys with placeholder values; the real values live only in the encrypted `*.enc.yaml`.
- Tokens, S3 keys, TLS material never appear in a non-encrypted `values.yaml`. Reference k8s Secrets via `existingSecret` / `envFrom` / `secretKeyRef`.

## Error handling

- **Fail fast and explicitly.** If `helm upgrade` warns, stop and read it — don't paper over it.
- Preview every change with `helm diff upgrade` (or `helm template`) before applying.
- Never silently ignore errors. Catch only what you can handle.

## Anti-Patterns to Avoid

- No commented-out manifest blocks "just in case" — git remembers.
- No TODO comments — open an issue or fix it now.
- No hardcoded image tags in values — pin explicit versions. No `latest`.
- No silent `--force` / `kubectl delete` to "make it apply" — figure out *why* it conflicts.
- No reaching for Helmfile / Fleet / a generic raw-manifest wrapper — this repo is plain local Helm charts, like the rest of the fleet.

## Code Review Checklist

Before considering work complete:

- [ ] All unused code/values removed
- [ ] Comments updated to reflect current implementation
- [ ] No config duplication (DRY applied)
- [ ] Error handling is explicit
- [ ] Resource limits and probes set on every container we own
- [ ] Every chart version pinned (no `__REPLACE__` / `# [verify]` left)
- [ ] No secrets in code or non-encrypted `values.yaml`
- [ ] `helm lint` / `helm template ./cluster/<tier>/<chart>` render clean; `secrets.py lint` passes
