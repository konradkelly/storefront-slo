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
# A webhook that isn't serving yet (a fresh operator's) fails the first attempt. Try again instead of giving up.
retry:
  limit: 10
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 3m
{{- end }}
