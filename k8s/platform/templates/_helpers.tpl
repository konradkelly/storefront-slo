{{/* Sync policy for every platform app. */}}
{{- define "platform.syncPolicy" -}}
automated:
  prune: true
  selfHeal: true
syncOptions:
  - CreateNamespace=true
  # Large CRDs (kube-prometheus-stack's, Gateway API's) and the dashboard ConfigMap overflow the 256 KiB
  # last-applied annotation that client-side apply keeps.
  - ServerSideApply=true
# A webhook that isn't serving yet (a fresh operator's), or an API server too busy to answer (a new kind cluster pulling
# every image at once: "etcdserver: request timed out"), fails an attempt. Keep trying every few minutes instead of
# giving up: after its last retry, Argo CD doesn't sync the same commit again on its own.
retry:
  limit: -1 # no limit
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 3m
{{- end }}
