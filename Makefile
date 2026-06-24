# mgmt-01 — SOPS + age secret workflow + plain-Helm deploy.
#
# Layout matches the fleet (home-lab-01, onion-*): each platform service is a local Helm chart under
# cluster/<infra|platform>/<chart>, deployed with `helm upgrade --install`. Secrets are co-located
# (cluster/<tier>/<chart>/<name>.enc.yaml), SOPS-encrypted, and — except the cloudflared token — are
# real k8s Secret manifests applied out of band so Helm never owns them. Full strategy: docs/secrets.md.
#
# The secret targets delegate to scripts/secrets.py (the fleet-standard SOPS tool): it guards the
# kube-context (only mgmt-01[-remote]) and the age key (XDG path, fleet key).

SHELL := /bin/bash
# Use the fleet age key at the XDG path (matches scripts/secrets.py — one key, every repo).
export SOPS_AGE_KEY_FILE := $(HOME)/.config/sops/age/keys.txt

SECRETS := ./scripts/secrets.py
HELM := helm upgrade --install
# Out-of-band k8s Secret manifests = every co-located *.enc.yaml EXCEPT the cloudflared token
# (that one is a helm-secrets values overlay rendered by its chart, not applied with kubectl).
ENC_FILES := $(shell find cluster -name '*.enc.yaml' -not -path '*/cloudflared/*' 2>/dev/null)

.PHONY: help namespaces sops-edit secrets-encrypt secrets-apply secrets-decrypt secrets-lint secrets-verify \
        deploy deploy-downstream

help:
	@echo "mgmt-01 — deploy (plain Helm; charts under cluster/<infra|platform>/<chart>):"
	@echo "  make namespaces          kubectl apply -f bootstrap/namespaces.yaml (run once, first)"
	@echo "  make secrets-apply       apply every out-of-band Secret (scripts/secrets.py apply)"
	@echo "  make deploy              namespaces + secrets + helm upgrade --install all local charts"
	@echo "  make deploy-downstream c=CONTEXT  push the observability agent to a workload cluster"
	@echo ""
	@echo "mgmt-01 — secrets (SOPS + age; delegates to scripts/secrets.py; see docs/secrets.md):"
	@echo "  make sops-edit f=PATH    edit a co-located *.enc.yaml in place (decrypt -> editor -> re-encrypt)"
	@echo "  make secrets-encrypt     encrypt any still-plaintext co-located *.enc.yaml in place"
	@echo "  make secrets-decrypt     print decrypted out-of-band secrets to stdout (review only)"
	@echo "  make secrets-lint        fail if any *.enc.yaml is plaintext or stray decrypted files exist"
	@echo "  make secrets-verify      list which secrets exist in the cluster"
	@echo ""
	@echo "  (new operator? your fleet age key at $$SOPS_AGE_KEY_FILE already decrypts — recipients"
	@echo "   live in .sops.yaml. Onboarding is documented in docs/secrets.md.)"

# --- Deploy (plain Helm) -----------------------------------------------------
# Pin every __REPLACE__ chart version (Chart.yaml dependencies / first-party appVersion) first.
# cloudflared is installed LAST and will fail until its tunnel token is set (Cloudflare-issued):
#   sops cluster/infra/cloudflared/secrets.enc.yaml
namespaces:
	kubectl apply -f bootstrap/namespaces.yaml

deploy: namespaces secrets-apply
	helm dependency build ./cluster/infra/local-path-provisioner && $(HELM) local-path-provisioner ./cluster/infra/local-path-provisioner -n local-path-storage
	$(HELM) garage ./cluster/infra/garage -n object-store
	helm dependency build ./cluster/infra/registry-cache && $(HELM) registry-cache ./cluster/infra/registry-cache -n registry-cache
	helm dependency build ./cluster/platform/monitoring  && $(HELM) rancher-monitoring ./cluster/platform/monitoring -n cattle-monitoring-system
	helm dependency build ./cluster/platform/logging     && $(HELM) loki ./cluster/platform/logging -n cattle-logging-system
	# rancher-backup needs its CRD chart installed FIRST (its pre-install hook blocks otherwise).
	helm dependency build ./cluster/platform/rancher-backup-crd && $(HELM) rancher-backup-crd ./cluster/platform/rancher-backup-crd -n cattle-resources-system
	helm dependency build ./cluster/platform/rancher-backup     && $(HELM) rancher-backup     ./cluster/platform/rancher-backup     -n cattle-resources-system
	$(HELM) cloudflared ./cluster/infra/cloudflared -n cloudflared -f secrets://cluster/infra/cloudflared/secrets.enc.yaml

deploy-downstream:
	@test -n "$(c)" || { echo "usage: make deploy-downstream c=<kube-context>"; exit 1; }
	helm dependency build ./cluster/downstream/observability-agent
	$(HELM) obs-agent ./cluster/downstream/observability-agent -n cattle-monitoring-system --kube-context $(c)

# --- Secrets (delegated to scripts/secrets.py) -------------------------------
sops-edit:
	@test -n "$(f)" || { echo "usage: make sops-edit f=cluster/infra/garage/garage-secrets.enc.yaml"; exit 1; }
	$(SECRETS) edit $(f)

secrets-encrypt:
	@test -n "$(ENC_FILES)" || { echo "no co-located *.enc.yaml found under cluster/"; exit 1; }
	@for x in $(ENC_FILES); do \
	  if sops --input-type yaml -d "$$x" >/dev/null 2>&1; then \
	    echo "already encrypted: $$x"; \
	  else \
	    echo "encrypting:        $$x"; $(SECRETS) encrypt "$$x"; \
	  fi; \
	done

secrets-apply: namespaces
	@test -n "$(ENC_FILES)" || { echo "no out-of-band *.enc.yaml to apply"; exit 1; }
	@for x in $(ENC_FILES); do \
	  echo "applying: $$x"; $(SECRETS) apply "$$x"; \
	done

secrets-decrypt:
	@for x in $(ENC_FILES); do echo "# --- $$x ---"; $(SECRETS) view "$$x"; echo; done

secrets-lint:
	$(SECRETS) lint

secrets-verify:
	@kubectl get secret -n object-store garage-secrets 2>/dev/null || echo "MISSING: object-store/garage-secrets"
	@kubectl get secret -n cattle-resources-system garage-s3-creds backup-encryption 2>/dev/null || echo "MISSING: cattle-resources-system creds"
	@kubectl get secret -n cattle-monitoring-system thanos-objstore 2>/dev/null || echo "MISSING: cattle-monitoring-system/thanos-objstore"
	@kubectl get secret -n cattle-logging-system loki-s3-creds 2>/dev/null || echo "MISSING: cattle-logging-system/loki-s3-creds"
