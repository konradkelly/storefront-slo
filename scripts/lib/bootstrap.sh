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

# kind only: a pull-through cache per registry, so a rebuilt cluster pulls ~4 GB of images from local disk instead of
# the internet (37 minutes on 2026-10-31, almost all of it pulls). The caches are containers on the host's Docker,
# outside the cluster, so `kind delete cluster` keeps them; each stores its images in a named volume. Remove them
# with: docker rm -f $(docker ps -aq -f name=kind-cache-) && docker volume rm $(docker volume ls -q -f name=kind-cache-)
# Cached images are kept for 30 days after their last pull.
# public.ecr.aws (Argo CD's Redis) isn't cached: the proxy can't get an anonymous token there ("unauthorized").
REGISTRY_CACHE_IMAGE=registry:3.1.2
IMAGE_CACHES="docker.io=https://registry-1.docker.io quay.io=https://quay.io ghcr.io=https://ghcr.io registry.k8s.io=https://registry.k8s.io"

start_image_caches() {
  local entry registry upstream name
  for entry in $IMAGE_CACHES; do
    registry=${entry%%=*} upstream=${entry#*=} name=kind-cache-${registry//./-}
    if [ -z "$(docker ps -q -f "name=^$name$")" ]; then
      docker rm -f "$name" >/dev/null 2>&1 || true
      docker run -d --restart=always --name "$name" -v "$name:/var/lib/registry" \
        -e REGISTRY_PROXY_REMOTEURL="$upstream" -e REGISTRY_PROXY_TTL=720h "$REGISTRY_CACHE_IMAGE" >/dev/null
      echo "started $name (caches $registry)"
    fi
  done
}

# After the cluster exists: put the caches on kind's network and point every node's containerd at them
# (config_path in k8s/kind-config.yaml). A cache that's down makes containerd fall back to the registry itself.
use_image_caches() { # cluster name
  local entry registry upstream name node
  for entry in $IMAGE_CACHES; do
    registry=${entry%%=*} upstream=${entry#*=} name=kind-cache-${registry//./-}
    docker network connect kind "$name" >/dev/null 2>&1 || true # already connected is fine
    for node in $(kind get nodes --name "$1"); do
      # MSYS_NO_PATHCONV: Git Bash would turn /etc/... into C:/Program Files/Git/etc/..., inside the node too.
      MSYS_NO_PATHCONV=1 docker exec "$node" mkdir -p "/etc/containerd/certs.d/$registry"
      printf 'server = "%s"\n\n[host."http://%s:5000"]\n  capabilities = ["pull", "resolve"]\n' "$upstream" "$name" |
        MSYS_NO_PATHCONV=1 docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/$registry/hosts.toml"
    done
  done
}
