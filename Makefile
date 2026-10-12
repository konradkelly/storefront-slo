# Thin wrappers over scripts/, so the scripts stay the single source of truth (and run without make:
# `bash scripts/k3s-up.sh`). On Windows, make comes from `winget install ezwinports.make`; run it from Git Bash.

SHELL := bash

.PHONY: help up down plan keep unkeep kind-up argocd-kind

help:
	@echo "make up            k3s on EC2 (Phase 4a): terraform apply + platform + Argo CD. Costs ~\$$0.15/hr."
	@echo "make down          destroy the k3s environment (back to \$$0/day)"
	@echo "make plan          terraform plan for the k3s environment, no changes"
	@echo "make keep HOURS=72 skip the nightly destroy until then (a soak run; max 7 days)"
	@echo "make unkeep        nightly destroy applies again"
	@echo "make kind-up       local kind lab"
	@echo "make argocd-kind   Argo CD on the kind lab"

up:
	bash scripts/k3s-up.sh

down:
	bash scripts/k3s-down.sh

plan:
	terraform -chdir=terraform/aws/k3s init -input=false -reconfigure \
	  -backend-config="bucket=storefront-pulse-tfstate-$$(aws sts get-caller-identity --query Account --output text)" >/dev/null
	terraform -chdir=terraform/aws/k3s plan -input=false

# The nightly destroy (.github/workflows/k3s-nightly-destroy.yml) skips while K3S_KEEP_UNTIL is in the future.
keep:
	@test -n "$(HOURS)" || { echo "usage: make keep HOURS=72"; exit 1; }
	gh variable set K3S_KEEP_UNTIL --body "$$(date -u -d '+$(HOURS) hours' +%Y-%m-%dT%H:%M:%SZ)"
	@gh variable get K3S_KEEP_UNTIL

unkeep:
	gh variable delete K3S_KEEP_UNTIL

kind-up:
	bash scripts/kind-up.sh

argocd-kind:
	bash scripts/argocd-up.sh kind
