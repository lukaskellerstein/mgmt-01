# Next Steps — Future Enhancements

Things we deliberately deferred. Captured here so the intent isn't lost. These are **not**
part of the current bringup — revisit when the trigger conditions below are met.

---

## Policy enforcement — Kubewarden

**Status:** deferred — not deployed and **not** in the repo. The earlier scaffold bundle
(`fleet/local/kubewarden/`) and its wiring (README component row, `bootstrap.md` mention, and
the GitRepo path in `bootstrap/fleet-gitrepo-local.yaml`) were removed so nothing deploys it.
This doc is the sole record. Re-introduce it from scratch when adopting (see below).

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
- **Rancher/Fleet-native** — SUSE's own project, first-class in the ecosystem we already run
  (`cattle-*` namespaces, Fleet, rancher-backup).
- **Fleet-wide, central authoring** — author policy once on `mgmt-01`, enforce consistently
  across all downstream clusters (see `fleet/downstream/`).
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

### To adopt (rebuild the bundle)
1. Create `fleet/local/kubewarden/` with a `fleet.yaml` (helm repo `https://charts.kubewarden.io`,
   chart `kubewarden-controller`, namespace `cattle-kubewarden-system`). Pin a real chart version.
2. Add a `dependsOn` on cert-manager (Kubewarden requires it; already on mgmt-01).
3. Resolve chart ordering — `kubewarden-crds` → `kubewarden-controller` → `kubewarden-defaults`.
   Either split into sibling dirs each with a `fleet.yaml`, or sequence with `dependsOn`.
4. Re-add the path `- fleet/local/kubewarden` to `bootstrap/fleet-gitrepo-local.yaml`.
5. Start in **monitor/audit mode** (report violations without blocking), then flip policies to
   enforcing once the noise is understood.
6. Author an initial policy set (start with: no-privileged-pods, required resource limits).
7. (Optional) Restore the README component-table row and the `bootstrap.md` wave mention.
