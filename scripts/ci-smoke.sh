#!/usr/bin/env bash
# Uses an isolated kind cluster; never touches kind-storefront.
set -euo pipefail
cd "$(dirname "$0")/.."
cluster=storefront-ci
context=kind-$cluster
image=${1:-storefront-api:ci}
image_archive=$(mktemp)
k() { kubectl --context "$context" "$@"; }
diagnostics() {
  k -n storefront get pods,jobs -o wide || true
  k -n storefront get events --sort-by=.lastTimestamp || true
  k -n storefront logs deployment/storefront-api --all-containers --tail=100 || true
  k -n storefront logs deployment/storefront-db --tail=50 || true
}
trap 'result=$?; rm -f "$image_archive"; if ((result != 0)); then diagnostics; fi; exit "$result"' EXIT
docker tag "$image" storefront-api:ci
for dependency in postgres:16.14 grafana/k6:2.3.0; do
  docker image inspect "$dependency" >/dev/null 2>&1 || docker pull "$dependency"
done
# Docker Desktop's containerd image store can export multi-platform indexes
# without all referenced layers. Export only the runner/node platform.
docker image save --platform linux/amd64 -o "$image_archive" storefront-api:ci postgres:16.14 grafana/k6:2.3.0
kind load image-archive "$image_archive" --name "$cluster"
k apply -k k8s/overlays/ci
k -n storefront rollout status deployment/storefront-db --timeout=180s
# A changed database pod has a fresh emptyDir. Re-run Flyway on every smoke
# bootstrap rather than retaining an app connected to the previous fixture.
k -n storefront rollout restart deployment/storefront-api
k -n storefront rollout status deployment/storefront-api --timeout=300s
k -n storefront delete job smoke-warmup smoke-measured --ignore-not-found
k -n storefront create configmap k6-smoke --from-file=smoke.js=loadtest/smoke.js --dry-run=client -o yaml | k apply -f -
run_load() {
  local name=$1 duration=$2 warmup=$3
  # No Slack/monitoring credentials are present in this throwaway environment.
  cat <<EOF | k apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: storefront
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 240
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/component: loadtest
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: k6
          image: grafana/k6:2.3.0
          args: [run, /scripts/smoke.js]
          env:
            - {name: DURATION, value: "$duration"}
            - {name: WARMUP, value: "$warmup"}
            - {name: RUN_ID, value: "$name"}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits: {memory: 128Mi}
          volumeMounts:
            - {name: script, mountPath: /scripts}
      volumes:
        - name: script
          configMap: {name: k6-smoke}
EOF
  for ((attempt=0; attempt<90; attempt++)); do
    state=$(k -n storefront get job "$name" -o jsonpath='{.status.succeeded}:{.status.failed}')
    if [[ "$state" == 1:* ]]; then k -n storefront logs job/"$name"; return; fi
    if [[ "$state" == *:1 ]]; then k -n storefront logs job/"$name"; return 1; fi
    sleep 3
  done
  k -n storefront logs job/"$name" || true
  echo "$name timed out" >&2
  return 1
}
# Warm JVM/database before measuring. The measured run always has thresholds.
run_load smoke-warmup 30s true
run_load smoke-measured 2m false
