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
| -2 | `cloudnative-pg`, `keda`, `metrics-server`, `envoy-gateway`, `argo-rollouts`, `plugin-barman-cloud` (k3s) | operators and their CRDs and webhooks |
| -1 | `cluster-config`: Gateway, monitoring routes, Probe, node alerts (k3s) ([k8s/cluster](../k8s/cluster)), `prometheus-blackbox-exporter` | need the Gateway and Probe CRDs |
| 0 | `storefront` (`overlays/kind-gitops` or `overlays/k3s`) | needs CloudNativePG, KEDA, the Gateway, Argo Rollouts and the monitoring CRDs |

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
scripts/argocd-up.sh`, or turn off automated sync on that one Application. The storefront app prunes what leaves
git, except the namespace, the Postgres Cluster and its backup store, which carry `Prune=false` so a bad commit can't
delete the database. Its project only reaches the storefront namespace, while `platform` can change anything: whoever
can edit those Applications is a cluster admin. KEDA owns the API's replica count and Argo Rollouts the HTTPRoute's
weights; Argo CD ignores both.

What isn't in git: the Secrets made from local files (Slack webhook URLs, S3 and Grafana Cloud credentials), until
External Secrets in Phase 4b, and the root Application itself, which says which cluster this is. Argo CD doesn't
manage its own installation either; `argocd-up.sh` applies the pinned upstream manifest.

## Canary releases

Every change to the API's pod template (a new image digest from the release workflow, an env var, a resource
limit) goes out as a canary, judged by the SLIs and rolled back without anyone running kubectl.

- **Argo Rollouts** (a platform app) runs the pods. The `Rollout` ([k8s/base/rollout.yaml](../k8s/base/rollout.yaml))
  takes its pod template from the Deployment (`workloadRef`), which stays at 0 replicas, so overlays and scripts
  still patch a Deployment, and the CI overlay, which has no Argo Rollouts, runs the Deployment directly.
- **Steps:** 20% of the Gateway's traffic for 5 minutes, then 50% for 5 minutes, then all of it. The Gateway API
  plugin sets the weights on the HTTPRoute's two backends, `storefront-api` (stable) and `storefront-api-canary`.
  Only traffic through the Gateway is split: in-cluster callers of the Service reach the stable version only, which
  is why the k6 Job now goes through the Gateway.
- **Analysis**, once a minute from the 20% step on: each version's checkout and catalog 5xx ratios, as burn rates
  against the SLO budgets ([prometheus/rules/canary.yml](../prometheus/rules/canary.yml), grouped by the pods'
  `rollouts-pod-template-hash` label, which the PodMonitor copies onto every series). If the canary burns more than
  6 faster than stable over the same 5 minutes (6 is the slow-burn page threshold, 3% errors for checkout), and the
  difference is beyond chance (a two-proportion z-test, z > 3), it aborts: traffic goes back to stable and the canary
  pods are removed. Without the z-test, an outage on both versions would abort good releases: while the 5-minute
  windows fill with errors, a canary with ~90 checkouts lands several points from stable by chance. Payment declines
  (402) aren't counted: they come from the payment provider and hit both versions alike.
- **A pause, not an abort, when both versions fail.** If the canary's own burn rate is over 6 but it isn't clearly
  worse than stable (a database outage, an overloaded cluster), the analysis is inconclusive and the Rollout pauses. It
  doesn't blame a good release for the outage, and doesn't promote it into one. Once the outage is over and the
  5-minute windows have cleared (resuming sooner pauses it again): `kubectl argo rollouts promote storefront-api -n
  storefront` to carry on, or `abort` to go back to stable. Without the kubectl plugin, the same resume is
  `kubectl -n storefront patch rollout storefront-api --subresource=status --type=merge -p '{"status":{"pauseConditions":null}}'`,
  or Resume on the Rollout in Argo CD.
- **No verdict** before the canary has served 50 requests of a kind: the check returns 0 and passes, but only while
  Prometheus is scraping a canary pod. If Prometheus can't see the canary at all, the check errors, and 4 errors in
  a row abort. A release that arrives while nobody is shopping is promoted unjudged; the SLO alerts are the backstop.
- **After an abort**, Argo CD shows the storefront Synced but Degraded: git still asks for the bad version. The fix is
  a revert in git, which returns to the stable version instantly (its pods never stopped).

### Experiment: a bad release (2026-10-31, kind)

`BUG_MODE=true` makes 10% of checkouts fail with a 500. Shipped from a throwaway branch (`canary-exp`, an image built
from this branch and loaded into the nodes) under k6 checkout-stress at 6 VUs, about 5,300 valid checkouts an hour,
through the Gateway.

| Time | |
|------|-|
| 20:40:40 | bad release pushed |
| 20:41:25 | canary at 20%; analysis starts |
| 20:42-20:44 | under 50 canary checkouts: no verdict (`[0]`), pass |
| 20:45:27 | 50 checkouts reached: burn rate 21.7, over 6, failed |
| 20:45:41 | rollout aborted, traffic back to 100% stable, canary pod removed 30 s later |
| 20:46:43 | revert in git: Synced/Healthy |

The stable version had 0 errors throughout, and no alert paged. Error budget spent:

| | Failed checkouts | Share of the 28-day budget (~17,700 at this traffic) |
|---|---|---|
| Canary, actual | 8.5 (of 84.5 the canary served) | 0.05% |
| Full rollout, the same 6 minutes | ~53 | 0.3% |
| Full rollout until the fast-burn page (~43 min at 10% errors) | ~377 | 2.1% |

So the canary cost about a sixth of the same minutes at 100%, and about 2% of waiting for the page, before anyone
had even started to respond. Detection took 4 minutes 16 seconds from the canary's first traffic, most of it waiting
for 50 checkouts.

The first attempt, an hour earlier, promoted the bad release, and that's how the analysis got its current shape:

- kind overloaded: 10 VUs, a canary pod, and a stray pod from the Deployment (Argo CD reset its missing `replicas` to
  1 whenever the template changed; it's 0 in git now). Postgres's primary restarted 9 times, and the canary's series
  disappeared from Prometheus. The first analysis read an empty result as "too few requests" and passed every check.
  Now it passes without a verdict only while `up == 1` for a canary pod.
- Just after that attempt's good release was promoted, the new stable version threw about 95 database errors
  (`CannotCreateTransactionException`, on every route) in 8 minutes. Had that landed during a canary, the analysis would have failed
  a good release: it judged the canary's errors in absolute terms. Since 2026-11-07 it compares the canary with
  stable over the same minutes, and pauses when both are failing (above, and the next experiment).

Other things that took a few tries, each with a comment where it's fixed:

- **The ServiceMonitor became a PodMonitor.** Argo Rollouts narrows each Service's selector to one version, so a
  Service-based scrape loses the other one. The old ServiceMonitor also matched the new canary Service, and with
  pruning off it stayed behind and scraped the stable pods twice; the storefront app prunes now.
- **No RespectIgnoreDifferences.** It copies ignored live fields into the sync with a merge patch, which replaces a
  whole list: the HTTPRoute kept its live one-backend list, the canary backend never arrived, and the plugin failed
  ("backendRef was not found"). `ApplyOutOfSyncOnly` leaves a route that differs only in weights alone instead.
- **Don't change the Deployment's template when introducing the Rollout.** A template change starts the
  Deployment's own rolling update next to the Rollout's new pods; on kind, 7 JVMs starting at once took Postgres down.
- **More 60-second leases on kind:** Argo Rollouts and Envoy Gateway (30 restarts in an afternoon), like the others.

### Experiment: a database outage during a canary (2026-11-07, k3s)

Does a good release survive an outage that hits both versions? The release was `1d2fe34`, the z-test change itself,
under k6 checkout-stress at 6 VUs through the Gateway (about 80 checkouts a minute). Postgres went down with
CloudNativePG's declarative hibernation (`kubectl annotate cluster storefront-db cnpg.io/hibernation=on`), which stops
both instances and keeps their volumes, and came back with `=off`.

| Time | |
|------|-|
| 17:30:19 | canary at 20%; analysis starts |
| 17:32:49 | 50 canary checkouts in 5 minutes: judged on real traffic, burn rate 0, z 0 |
| 17:33:59 | Postgres hibernated |
| 17:35:19 | catalog's own burn rate 9.6, over 6: inconclusive. Both comparisons 0. Rollout paused (`InconclusiveAnalysisRun`) |
| 17:36:10 | Postgres woken; serving again about a minute later, same primary and timeline (no failover) |
| 17:41 | the canary's 5-minute windows clear |
| 17:54:19 | resumed (status patch, above) |
| 18:00 | promoted, after the 50% step passed with 193 canary and 288 stable checkouts, no errors |

The outage paged as it should: fast-burn pages for cart and catalog availability from 17:36 to 17:51, and tickets.
No data was lost: the orders from the restore test kept their checksum.

**Did the z-test matter?** Replaying the comparison's recording rules for the outage, at every 30-second evaluation
(burn rates are the canary's and stable's own; the old rule aborted on a difference over 6):

| | Canary | Stable | Difference | z | Old rule | Now |
|---|---|---|---|---|---|---|
| checkout 17:35:30 | 7.3 | 0.8 | 6.4 | 2.5 | abort | pass |
| checkout 17:36:00 | 12.7 | 4.1 | 8.6 | 1.9 | abort | pass |
| checkout 17:36:30 | 16.2 | 7.3 | 8.9 | 1.5 | abort | pass |
| catalog 17:35:00 | 9.6 | 11.8 | -2.2 | -0.3 | pass | pass |
| catalog 17:35:30 | 18.7 | 28.4 | -9.7 | -0.8 | pass | pass |
| catalog 17:36:00 | 43.3 | 46.3 | -3.0 | -0.2 | pass | pass |
| catalog 17:36:30 | 80.2 | 74.1 | 6.1 | 0.3 | abort | pass |

The noise was as large as expected: catalog's difference swung from -9.7 to +6.1 within a minute. In this run, though,
the old rule would have paused too. The difference can never exceed the canary's own burn rate, so the old rule
aborts only if both cross 6 at the same once-a-minute check, and a failed check beats an inconclusive one. The first
check after the outage began landed at 17:35:19, when only catalog's own burn rate had crossed, so the run paused and
stopped measuring. A check at 17:35:30 would have seen checkout's difference at 6.4 and aborted a good release. The
z-test makes the outcome independent of where the check lands.

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
