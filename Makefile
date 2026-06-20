# mgmt-01 — SOPS + age secret workflow.
#
# Encrypted source of truth: secrets/*.enc.yaml (committed, safe).
# Fleet does NOT decrypt SOPS, so secrets are applied OUT OF BAND with
# `make secrets-apply` during bootstrap and on rotation. Everything else on the
# box is reconciled by Fleet from this repo.

SHELL := /bin/bash
AGE_KEY_FILE ?= age/keys.txt
export SOPS_AGE_KEY_FILE := $(AGE_KEY_FILE)

ENC_FILES := $(wildcard secrets/*.enc.yaml)
# Namespaces that must exist before secrets land. cattle-* are normally created by
# Rancher/charts; we ensure them idempotently so a secret can be applied first.
SECRET_NAMESPACES := object-store cattle-resources-system cattle-monitoring-system cattle-logging-system cloudflared

.PHONY: help age-init sops-edit secrets-encrypt secrets-apply secrets-decrypt secrets-verify

help:
	@echo "mgmt-01 secret workflow (SOPS + age):"
	@echo "  make age-init            generate age/keys.txt and print the public recipient for .sops.yaml"
	@echo "  make sops-edit f=NAME    edit secrets/NAME.enc.yaml in place (decrypt -> editor -> re-encrypt)"
	@echo "  make secrets-encrypt     encrypt any still-plaintext secrets/*.enc.yaml in place"
	@echo "  make secrets-apply       decrypt every secrets/*.enc.yaml and kubectl apply (out-of-band)"
	@echo "  make secrets-decrypt     print decrypted secrets to stdout (review only)"
	@echo "  make secrets-verify      list which secrets exist in the cluster"

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
	@kubectl get secret -n cloudflared tunnel-token 2>/dev/null || echo "MISSING: cloudflared/tunnel-token"
