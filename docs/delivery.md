# Delivery on kind

CI and release have separate permissions. `CI` runs on every PR/main push and checks Java,
Prometheus, rendered manifests and a disposable Kubernetes checkout smoke test. `Release` runs
only after successful main CI from this repository. It builds the checked source revision,
scans HIGH/CRITICAL vulnerabilities (including unfixed ones), generates a CycloneDX SBOM,
publishes `ghcr.io/konradkelly/storefront-slo:<full-git-sha>`, and signs/attests the digest
with cosign using GitHub OIDC. It then commits the digest into `overlays/kind-gitops` on main.

The release needs GitHub's built-in `GITHUB_TOKEN`, with `packages: write`, `contents: write`,
and `id-token: write` as declared in the job. No personal token or kubeconfig is stored in Actions.
Signature and SBOM attestations are public registry/transparency-log artifacts. Image scans and
the SBOM are also retained in the workflow's `image-security-*` artifact.

## First release

Local validation on 2026-10-07 found 42 HIGH/CRITICAL findings in the Spring Boot 3.3.4 image's
Java dependencies (34 HIGH, 8 CRITICAL), and the gate blocked publishing. Fixed 2026-10-12:

- Spring Boot 3.3.4 → **4.1.1** (Spring Framework 7.0.9; CVE-2026-47884 has no 6.x fix).
- Tomcat 11.0.25 and Jackson 3.1.7 pinned ahead of Boot's managed versions (`app/pom.xml`).
  Remove the pins once a Boot release manages these or newer.
- Runtime base `eclipse-temurin:21.0.12.1_1-jre-noble` (Ubuntu 24.04). The default tag moved to
  Ubuntu 26.04, whose image adds a `pebble` Go binary with HIGH Go stdlib CVEs.

`scripts/scan-image.sh` then passed locally with 0 HIGH/CRITICAL findings, and no vulnerabilities
are waived.

The first hosted release succeeded on 2026-10-12 (run 38318364911, source `a01eeb0`), after one
more fix: cosign-installer v3 can't install cosign 3, which ships `.sigstore.json` bundles instead
of `.sig` files, so the installer is now v4.1.2. The promotion commit `d566660` pinned
`sha256:0769ce23…` in both GitOps overlays. The package inherited the repository's public
visibility, so anonymous pulls work without changing settings. Anyone can verify the signature
with the `cosign verify` command below and the digest `sha256:0769ce23fbe0764f7b4272da9457a0571244a4ecf837f9716e9fc31f7b46be20`.

1. Push the workflows and supporting files to main. CI must pass before Release can publish.
   Run CI manually on main to retry without changing source.
2. Check the Release job for a successful scan, image push, signature and promotion commit.
   Make the GHCR package **public** after first publication: packages can initially be private
   even when their source repository is public. Public visibility lets kind pull without credentials.
3. Pull the promotion commit locally before installing the Argo CD Application.

The promotion is a normal fast-forward push. If main has advanced, the older release leaves
promotion to the newer source's CI. If branch protection disallows the bot's push, Release fails
at promotion; submit the digest change through a reviewed PR instead of disabling protection.
GitHub does not trigger another workflow from a `GITHUB_TOKEN` push, preventing a release loop.

To verify an image signature (replace the reference with the published digest):

```bash
cosign verify \
  --certificate-identity 'https://github.com/konradkelly/storefront-slo/.github/workflows/release.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/konradkelly/storefront-slo@sha256:...
```

Signing records provenance; admission enforcement of signatures is future work.

## Argo CD

Argo CD installs the whole cluster from git, not only the app. `scripts/kind-up.sh` (and `k3s-up.sh`) create the
cluster, its network plugin and the Secrets that come from local files, then run `scripts/argocd-up.sh`. That
installs Argo CD and one root Application, `platform`, which renders [k8s/platform](../k8s/platform): a Helm chart
whose output is one Application per add-on, plus the storefront.

| Wave | Applications | Why this order |
|------|--------------|----------------|
| -5 | projects `platform`, `storefront` | the Applications below belong to them |
| -4 | `monitoring-config`: Alertmanager config Secret, dashboards, alert logger ([k8s/cluster/monitoring](../k8s/cluster/monitoring)) | Alertmanager won't start without its config |
| -3 | `kube-prometheus-stack`, `cert-manager` (k3s) | the ServiceMonitor, PodMonitor and PrometheusRule CRDs the other charts use |
| -2 | `cloudnative-pg`, `keda`, `metrics-server`, `envoy-gateway`, `plugin-barman-cloud` (k3s) | operators and their CRDs and webhooks |
| -1 | `cluster-config`: Gateway, monitoring routes, Probe, node alerts (k3s) ([k8s/cluster](../k8s/cluster)), `prometheus-blackbox-exporter` | need the Gateway and Probe CRDs |
| 0 | `storefront` (`overlays/kind-gitops` or `overlays/k3s`) | needs CloudNativePG, KEDA, the Gateway and the monitoring CRDs |

Chart versions and values files are in [k8s/platform/values.yaml](../k8s/platform/values.yaml), with per-cluster
overrides in `values-kind.yaml` and `values-k3s.yaml`. The Alertmanager config, Slack template, logger script and
dashboards are built from the same files Compose reads (`alertmanager/`, `grafana/dashboards/`), so there's one copy
of each.

Things that took a few tries on the first rebuild (2026-10-31), each with a comment where it's fixed:

- **A wave waits only while a child is Progressing.** Argo CD's documented health check for Applications passes the
  child's health through, so a child that hadn't synced yet (Missing) or whose first attempt failed (Degraded) let
  the next wave start. The Envoy Gateway CRDs had timed out, and `cluster-config` failed with "EnvoyProxy not found".
  [k8s/argocd/argocd-cm.yaml](../k8s/argocd/argocd-cm.yaml) counts a child as Progressing until it has synced and
  stopped retrying. Retries have no limit, because after its last retry Argo CD doesn't sync the same commit again.
- **Server-side apply needs server-side diff.** The platform apps apply server-side, because the biggest CRDs and the
  dashboard ConfigMap don't fit client-side apply's 256 KiB annotation. Compared client-side, every default the API
  server fills in (an HTTPRoute backend's `kind`, `group`, `weight`) looked like drift, forever. Each platform
  Application sets `compare-options: ServerSideDiff=true`.
- **kind's control plane needs slack.** Bringing everything up at once slowed the API server enough that the controller
  manager and scheduler lost their leader leases and restarted every few minutes, which stopped Jobs, rollouts and
  garbage collection. They now hold their lease for 60 s ([k8s/kind-config.yaml](../k8s/kind-config.yaml)), and the
  node image is pinned to CI's v1.34.0; unpinned, kind v0.33 made 1.37 nodes.

Watch it from the UI:

```bash
kubectl --context kind-storefront -n argocd port-forward svc/argocd-server 8081:443
kubectl --context kind-storefront -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode
```

The UI is at `https://localhost:8081` (user `admin`). Or from the command line:
`kubectl --context kind-storefront -n argocd get applications`.

Every app self-heals, so a `kubectl apply` or `kubectl set env` gets undone within minutes. Make changes in git. To
try something before merging, push a branch and point the cluster at it with `REVISION=<branch> bash
scripts/argocd-up.sh`, or turn off automated sync on that one Application. The storefront app doesn't prune, so a bad
commit can't delete the database. Its project only reaches the storefront namespace, while `platform` can change
anything: whoever can edit those Applications is a cluster admin. KEDA owns the API's replica count; Argo CD ignores
that field.

What isn't in git: the Secrets made from local files (Slack webhook URLs, S3 and Grafana Cloud credentials), until
External Secrets in Phase 4b, and the root Application itself, which says which cluster this is. Argo CD doesn't
manage its own installation either; `argocd-up.sh` applies the pinned upstream manifest.

## Local smoke and security checks

```bash
docker build -t storefront-api:ci app
kind create cluster --name storefront-ci --image kindest/node:v1.34.0 --wait 120s
bash scripts/ci-smoke.sh
kind delete cluster --name storefront-ci
bash scripts/scan-image.sh storefront-api:ci /tmp/storefront-image-reports
```

The isolated CI overlay reuses app probes, graceful shutdown and security settings, but uses
one app pod and ephemeral Postgres without operators. Like the kind overlay, it disables
synchronous commits to avoid Docker Desktop WAL-flush stalls; this is not a durability test.
It does not measure the full lab's
failover, Gateway or NetworkPolicy enforcement. The load test warms up for 30 seconds, then
measures two minutes with five users: checkout availability >99.5%, checkout p99 <500ms,
and catalog/cart HTTP availability >99.9%. Payment randomness is disabled and stock is ample.
These are short release regression gates, not evidence that a 28-day SLO is met.

Checkout 402/5xx/transport failures count as bad; 400/409 are excluded from that availability
ratio. Separately, the deterministic fixture requires every checkout to return 201, so stockouts
or malformed requests cannot make CI green by emptying the SLI denominator.

Local validation passed with 516 checkouts, zero failed requests and reported p99 233ms. A separate
payment-outage negative test returned 65 HTTP 402s: generic HTTP failure rate stayed at zero,
but checkout error ratio was 100% and the Job failed. WSL clock jumps remain a documented lab
measurement limitation (see the roadmap); use hosted CI for the release decision.

Keep reports outside the repository; do not commit vulnerability database/cache contents.
