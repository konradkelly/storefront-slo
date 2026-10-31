#!/bin/bash
# What kind-up.sh and k3s-up.sh still do themselves before Argo CD takes over (scripts/argocd-up.sh). Everything
# else, from monitoring to the storefront, is in git (k8s/platform). What's left is what can't be in git: Secrets
# made from local files, until External Secrets in Phase 4b. Sourced after CTX (the kubeconfig context) is set;
# every call names that context, so other clusters are never touched.
#
# Run from the repo root.

k() { kubectl --context "$CTX" "$@"; }
step() { echo; echo "== $*"; }

# Slack webhook URLs for Alertmanager, from the gitignored alertmanager/secrets/ files. Mounted by
# alertmanagerSpec.secrets in k8s/monitoring/kps-values.yaml.
create_slack_secret() {
  k create namespace monitoring --dry-run=client -o yaml | k apply -f -
  local secret_args=() f
  for f in slack-page-url slack-ticket-url; do
    if [ -s "alertmanager/secrets/$f" ]; then
      secret_args+=("--from-file=$f=alertmanager/secrets/$f")
    else
      echo "alertmanager/secrets/$f missing: Slack sends will fail, alert-logger still receives everything"
      secret_args+=("--from-literal=$f=")
    fi
  done
  k -n monitoring create secret generic alertmanager-slack "${secret_args[@]}" --dry-run=client -o yaml | k apply -f -
}
