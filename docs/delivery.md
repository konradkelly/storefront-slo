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

Local validation on 2026-10-07 found 42 HIGH/CRITICAL findings in the current Spring Boot 3.3.4
image's Java dependencies (34 HIGH, 8 CRITICAL). The gate blocks publishing; the dependency
migration needs to clear it before the first successful release. SBOM/report generation and
the gate's nonzero exit were verified locally. Registry signing/promotion await a hosted run.

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

The existing lab must have its operators installed (CloudNativePG, KEDA, monitoring, Gateway).
Bootstrap it with `bash scripts/kind-up.sh`, then:

```bash
bash scripts/argocd-up.sh
kubectl --context kind-storefront -n argocd port-forward svc/argocd-server 8081:443
```

The UI is at `https://localhost:8081`. Retrieve the initial password locally:

```bash
kubectl --context kind-storefront -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode
```

The bootstrap deliberately stops before applying the Application if the image still says
`awaiting-first-release`. After the first promotion, applying `k8s/argocd/storefront.yaml`
enables automated sync/self-healing. The Project permits this source repository and the
storefront namespace. Pruning is disabled to avoid unattended database or namespace deletion.
KEDA owns replicas; Argo CD ignores and respects that field during sync.

`overlays/kind` continues to load local `:dev` images; `overlays/kind-gitops` pulls registry
digests. Once Argo owns the app, avoid rerunning kind-up.sh's app deployment or imperative
`kubectl set env`: Argo self-healing will restore Git's values. Make experiment/config changes
in Git, or temporarily disable self-healing for a deliberate lab experiment.

This first Application manages the storefront workloads and SLO rules. Moving the Helm
platform into an app-of-apps and sealing Slack secrets remain Phase 3.2 work. Argo Rollouts,
canary-specific recording rules, and the bad-release rollback experiment remain Phase 3.3.

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
