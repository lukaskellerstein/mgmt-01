# mgmt-01 — SOPS + age secret workflow + Helmfile deploy.
#
# Encrypted source of truth: secrets/*.enc.yaml (committed, safe).
# These out-of-band Secrets are applied with `make secrets-apply` so Helm never
# owns them. Everything else on the box is deployed from helmfile.yaml (`make deploy`).

SHELL := /bin/bash
AGE_KEY_FILE ?= age/keys.txt
export SOPS_AGE_KEY_FILE := $(AGE_KEY_FILE)

ENC_FILES := $(wildcard secrets/*.enc.yaml)
# Namespaces that must exist before secrets land. cattle-* are normally created by
# Rancher/charts; we ensure them idempotently so a secret can be applied first.
# (cloudflared needs no secret here — its token is a SOPS Helm values overlay.)
SECRET_NAMESPACES := object-store cattle-resources-system cattle-monitoring-system cattle-logging-system

.PHONY: help age-init sops-edit secrets-encrypt secrets-apply secrets-decrypt secrets-verify \
        deploy diff deploy-downstream

help:
	@echo "mgmt-01 secret workflow (SOPS + age):"
	@echo "  make age-init            generate age/keys.txt and print the public recipient for .sops.yaml"
	@echo "  make sops-edit f=NAME    edit secrets/NAME.enc.yaml in place (decrypt -> editor -> re-encrypt)"
	@echo "  make secrets-encrypt     encrypt any still-plaintext secrets/*.enc.yaml in place"
	@echo "  make secrets-apply       decrypt every secrets/*.enc.yaml and kubectl apply (out-of-band)"
	@echo "  make secrets-decrypt     print decrypted secrets to stdout (review only)"
	@echo "  make secrets-verify      list which secrets exist in the cluster"
	@echo ""
	@echo "mgmt-01 deploy (plain Helm via Helmfile):"
	@echo "  make diff                preview the local-cluster diff (helmfile diff)"
	@echo "  make deploy              install/upgrade all local-cluster releases (helmfile sync)"
	@echo "  make deploy-downstream c=CONTEXT  push the observability agent to a workload cluster"

# --- Deploy (Helmfile) -------------------------------------------------------
# Helm-first path. Run `make secrets-apply` first (Helm does not own the out-of-band
# secrets). Pin every __REPLACE__ chart version in helmfile.yaml before deploying.
diff:
	helmfile diff

deploy:
	helmfile sync

deploy-downstream:
	@test -n "$(c)" || { echo "usage: make deploy-downstream c=<kube-context>"; exit 1; }
	helmfile -f helmfile.downstream.yaml --kube-context $(c) sync

age-init:
	@mkdir -p $(dir $(AGE_KEY_FILE))
	@if [ -f $(AGE_KEY_FILE) ]; then \
	  echo "$(AGE_KEY_FILE) already exists — not overwriting."; \
	else \
	  age-keygen -o $(AGE_KEY_FILE); \
	fi
	@echo ""
	@echo "Public recipient — paste into .sops.yaml (age: ...):"
	@grep -i 'public key' $(AGE_KEY_FILE) | sed 's/.*public key: //'

sops-edit:
	@test -n "$(f)" || { echo "usage: make sops-edit f=garage-secrets"; exit 1; }
	sops secrets/$(f).enc.yaml

secrets-encrypt:
	@test -n "$(ENC_FILES)" || { echo "no secrets/*.enc.yaml yet — copy a .example.yaml first"; exit 1; }
	@for x in $(ENC_FILES); do \
	  if sops --input-type yaml -d "$$x" >/dev/null 2>&1; then \
	    echo "already encrypted: $$x"; \
	  else \
	    echo "encrypting:        $$x"; sops -e -i "$$x"; \
	  fi; \
	done

secrets-apply:
	@test -n "$(ENC_FILES)" || { echo "no secrets/*.enc.yaml to apply"; exit 1; }
	@for ns in $(SECRET_NAMESPACES); do \
	  kubectl create namespace "$$ns" --dry-run=client -o yaml | kubectl apply -f - ; \
	done
	@for x in $(ENC_FILES); do \
	  echo "applying: $$x"; sops -d "$$x" | kubectl apply -f - ; \
	done

secrets-decrypt:
	@for x in $(ENC_FILES); do echo "# --- $$x ---"; sops -d "$$x"; echo; done

secrets-verify:
	@kubectl get secret -n object-store garage-secrets 2>/dev/null || echo "MISSING: object-store/garage-secrets"
	@kubectl get secret -n cattle-resources-system garage-s3-creds backup-encryption 2>/dev/null || echo "MISSING: cattle-resources-system creds"
	@kubectl get secret -n cattle-monitoring-system thanos-objstore 2>/dev/null || echo "MISSING: cattle-monitoring-system/thanos-objstore"
	@kubectl get secret -n cattle-logging-system loki-s3-creds 2>/dev/null || echo "MISSING: cattle-logging-system/loki-s3-creds"
