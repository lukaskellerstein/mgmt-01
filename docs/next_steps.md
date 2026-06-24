# Next Steps — Future Enhancements

Things we deliberately deferred. Captured here so the intent isn't lost. These are **not**
part of the current bringup — revisit when the trigger conditions below are met.

---

## Policy enforcement — Kubewarden

**Status:** deferred — not deployed and **not** in the repo. There is no
`cluster/platform/kubewarden` chart and no namespace for it; this doc is the sole record.
Re-introduce it from scratch when adopting (see below).

### Why we want it
Kubewarden is SUSE's lightweight admission policy engine (Wasm-based; an OPA/Gatekeeper and
Kyverno alternative). It sits in front of the API server and inspects every create/update
**before** it's persisted — rejecting non-compliant resources (validating) or fixing them on
the way in (mutating). It enforces rules automatically instead of relying on humans to
remember them in review.

Typical guardrails:
- No containers running as root / no privileged pods.
- Every pod must declare CPU/memory limits.
- No `:latest` image tags; images only from trusted registries.
- Required ownership/cost labels on namespaces.
- Auto-inject default security contexts or labels (mutating policies).

### Why it fits this estate
- **Rancher/SUSE-native** — SUSE's own project, first-class in the ecosystem we already run
  (`cattle-*` namespaces, rancher-backup).
- **Fleet-wide, central authoring** — author policy once and apply the same chart to every
  downstream cluster across the NUC fleet (the same per-context pattern as
  `cluster/downstream/observability-agent`).
- **Governance story** — lets us *demonstrate* uniform control enforcement across the fleet
  (EU / compliance angle), not just hope CI pipelines catch things.
- **Lightweight** — Wasm policies, small footprint (controller requests `50m` CPU / `128Mi`).

### Why not now
Current setup doesn't need it yet: the operational trust model is small enough that admission
guardrails would be overhead before they pay off. We finish the core platform first.

### Adopt when
Any of these become true:
- Other teams/people start deploying to clusters we manage (need guardrails).
- A compliance/audit obligation requires *provable* enforced controls.
- We want defaults (security contexts, labels, limits) injected automatically.
- We need consistent rules across many clusters without per-pipeline copy-paste.

### To adopt (build the charts)
1. Add wrapper charts under `cluster/platform/kubewarden-*` from the Kubewarden repo
   (`https://charts.kubewarden.io`), namespace `cattle-kubewarden-system`. Pin real chart versions
   in each `Chart.yaml` dependency. Add the namespace to `bootstrap/namespaces.yaml`.
2. cert-manager is a prerequisite (Kubewarden requires it; install it on mgmt-01 first).
3. Respect chart ordering by deploy order — `kubewarden-crds` → `kubewarden-controller` →
   `kubewarden-defaults` (three charts/releases, installed in sequence).
4. Start in **monitor/audit mode** (report violations without blocking), then flip policies to
   enforcing once the noise is understood.
5. Author an initial policy set (start with: no-privileged-pods, required resource limits).
6. To enforce on downstream clusters too, copy the charts under `cluster/downstream/` and
   `helm upgrade --install ... --kube-context <cluster>` per cluster.
7. (Optional) Restore the README component-table row and the `bootstrap.md` wave mention.
