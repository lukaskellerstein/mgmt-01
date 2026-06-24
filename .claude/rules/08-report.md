# Step 5: Report

Provide a short summary to the user:
- What was changed (which chart/release, `values.yaml` keys, manifest kinds, secret files, docs touched)
- What was tested and what you observed (`helm diff`/`helm template` summary, `kubectl rollout status` output, `curl` HTTP codes, relevant log lines, `secrets.py lint` result)
- Current cluster state (which releases were installed/upgraded, namespaces affected, any resources left in a transient state — e.g. Wave-2 consumers still pending a Garage key)
- Whether `README.md` / `docs/` / in-values comments needed updating (or why they were skipped)
