# bootstrap/

One-time, cluster-level setup applied **by hand or CI** to stand `mgmt-01` up — the things that
exist *before* and *around* the platform charts, not workloads themselves.

What lands here:

- **`namespaces.yaml`** — the declarative source of truth for every namespace on this cluster.
  **Apply it first**, then deploy charts with `helm -n <ns>` and *without* `--create-namespace`,
  so namespaces are owned by git, not by a CLI flag. It's also where namespace-level policy lives
  (Pod Security Admission labels, etc.).

  ```bash
  kubectl apply -f bootstrap/namespaces.yaml
  ```

> The deeper foundation below this — OS + RKE2, cert-manager + Rancher (Helm), the Cloudflare
> tunnel — is documented in [`../docs/manual-setup.md`](../docs/manual-setup.md). It stays manual
> because Rancher needs a running cluster before Helm can install it (chicken-and-egg).

Until Fleet is adopted, deployment is imperative (`helm upgrade --install` — see the root README
"Deploy" section and [`../docs/bootstrap.md`](../docs/bootstrap.md)), but namespaces are already
declarative via `namespaces.yaml`.
