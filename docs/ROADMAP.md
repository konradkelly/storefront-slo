# Roadmap

Where StorefrontSLO goes after "instrumented API + threshold alerts on kind". The goal is a project
that shows the full loop: define SLOs, alert on error budget burn, deploy through a pipeline that
checks the SLO, and run the same thing on a real cloud cluster.

Each phase ends with a **Done when** check and an **Experiment** that breaks something on purpose.
The experiment is what turns the work into something you can explain in an interview.

| Phase | Theme | Main skills |
|-------|-------|-------------|
| 0 | Baseline fixes | Spring config, tests, pinned images |
| 1 | SLOs and error budgets | SLIs, recording rules, burn-rate alerts, Alertmanager, runbooks |
| 2 | Production-shaped Kubernetes | Migrations, StatefulSets/operators, probes, HPA/KEDA, PDBs, security |
| 3 | CI/CD and GitOps | GitHub Actions, promtool tests, image scanning, Argo CD, canary analysis |
| 4a | Cloud: k3s on EC2 | Terraform, EC2, self-managed Kubernetes, cost control |
| 4b | Cloud: migrate to EKS | Managed Kubernetes, pod IAM, External Secrets, RDS, zero-downtime cutover |
| 5 | Deeper reliability (stretch) | Tracing, logs, chaos engineering, resilience patterns |

Phases 1 to 3 are the core. Phase 4 costs money, so start it only after 3 works on kind.
Phase 4 starts with k3s because it's cheap and shows what a managed service does for you.
The EKS sprint then replaces those pieces one at a time.

---

## Phase 0: Baseline fixes

Small items that later phases depend on.

- [x] **Fix the leftover property name.** `Catalog.java` schedules restocks with
      `${shop.restock-interval-ms}`, but `application.yml` defines `storefront.restock-interval-ms`.
      Spring can't resolve the placeholder, so a fresh build fails on startup.
- [x] **Add tests.** Add `@SpringBootTest` with Testcontainers Postgres for checkout: success, empty cart,
      out of stock, and payment failure. Also assert that the right `storefront_checkouts_total` series moves.
      CI in Phase 3 needs these tests.
- [x] **Pin image tags.** Replace `prom/prometheus:latest`, `grafana/grafana:latest`, and `grafana/k6:latest`
      with specific versions so the environment can be reproduced.
- [x] **Commit the Grafana dashboard** from README Step 3 as JSON. On kind, provision it through a ConfigMap
      labeled `grafana_dashboard: "1"`, which the kube-prometheus-stack sidecar picks up.
- [x] **Run the container as non-root.** Add a `USER` to the runtime stage of the Dockerfile.
      Phase 2's Pod Security settings will require it.

**Done when:** `mvn verify` passes, and a clean `docker compose up --build` serves orders and shows the
dashboard without any manual steps. **Done 2026-09-30.**

Notes from finishing it:
- Docker Engine 29 rejects the API version Testcontainers' client sends by default, so the Surefire config sets
  `api.version=1.44`.
- The checkout test suite includes a scrape test that fails if a documented metric name stops matching
  what Prometheus actually sees.

---

## Phase 1: SLOs and error budgets

This phase is what the repo is named for. The current alerts use fixed thresholds ("failure ratio > 5% for 5m"),
so they can't tell a brief blip apart from a slow drain on reliability. Replace them with SLOs and burn-rate alerts.

### 1.1 Write the SLO spec (`docs/slo.md`)

Decide what counts as a good event and a bad event before writing any PromQL.

- [x] **Spec written** in [slo.md](slo.md) (2026-10-02): checkout availability 99.5%, checkout latency 99%,
      catalog availability 99.9%, cart availability 99.9%, all over 28d. Catalog latency is deferred until it
      has a baseline. Also done: payment failure default lowered to 0.1%, and the k6 script split into
      `browse` (realistic, default) and `checkout-stress` profiles.
- [x] Add the exact latency buckets (see below) and measure a `browse` baseline.

| SLO | SLI (good / valid) | Target | Window |
|-----|--------------------|--------|--------|
| Checkout availability | Checkouts that did not fail because of us / all checkout attempts | 99.5% | 28d rolling |
| Checkout latency | `POST /orders` served in < 500ms / all `POST /orders` | 99% | 28d rolling |
| Catalog availability | `GET /products*` non-5xx / all `GET /products*` | 99.9% | 28d rolling |
| Cart availability | `/cart/**` non-5xx / all `/cart/**` | 99.9% | 28d rolling |

Things to decide and write down:

- **Bad events vs. expected outcomes.** A payment failure returns **402**, so an SLI that only counts 5xx
  would stay green through a complete payment outage. Out of stock (409) is a business outcome and should
  not count against the SLO. Payment failures are the open question. With a real provider, some declines
  are legitimate, such as an expired card. Here, `PAYMENT_FAILURE_RATE` simulates the provider being down,
  so count `payment_failed` as bad and write down why.
- **Unhandled errors bypass the business counter.** If the DB pool times out, the request becomes a 500 before
  `OrderController` increments `storefront_checkouts_total`. So the availability SLI needs both
  sources: 5xx from `http_server_requests_seconds_count{uri="/orders"}` plus `payment_failed` from the
  business counter.
- **Latency buckets.** Micrometer's default histogram has no bucket at exactly 0.5s. The closest are 0.447s
  and 0.537s. Add exact boundaries so the SLI counts real good events and doesn't interpolate:
  ```yaml
  management.metrics.distribution.slo.http.server.requests: 100ms,300ms,500ms,1s
  ```
- **Measure the baseline before picking targets, after a warm-up.** The first run on a fresh database and
  JVM in Phase 0 showed only 75% of checkouts under 0.5s. That didn't reproduce on a warm app, so
  exclude warm-up from baselines. Under real contention the checkout design does matter. Measured on
  2026-10-01, with 30 k6 users for 2 minutes after a warm-up and 150ms payment latency:

  | Checkout | p95 | p99 | max | under 0.5s |
  |----------|-----|-----|-----|------------|
  | `CHECKOUT_MODE=single-tx` (payment inside the transaction) | 0.52s | 0.78s | 2.0s | 95.6% |
  | `CHECKOUT_MODE=saga` (default since 2026-10-01) | 0.24s | 0.25s | 0.43s | 100% |

  The cause was row locks, not the connection pool (pending stayed at 0 in both). This gives Phase 1 a
  ready-made story: define the latency SLO, show single-tx burning budget at 30 users, switch to saga,
  and show the burn rate drop. Design details: [architecture/checkout.md](architecture/checkout.md).
- **Window on a lab cluster.** A kind cluster never accumulates 28 days of data. Keep 28d in the spec,
  and add a 1d dashboard view so budget consumption is visible during an afternoon of experiments.

### 1.2 Recording rules (`k8s/base/slo-rules.yaml`)

- [x] Error ratio per SLO at 5m, 30m, 1h, 2h, 6h, 1d, and 3d windows, named like
      `slo:checkout_availability:error_ratio_rate1h`.
- [x] `slo:*:error_budget_remaining` over the SLO window.
      Done 2026-10-02. The source is `prometheus/rules/slo.yml`, loaded by Compose and wrapped into
      `k8s/base/slo-rules.yaml` by `scripts/gen-k8s-rules.sh`. Unit tests are in `prometheus/tests/slo_test.yml`.
      Applied to kind on 2026-10-03 by `scripts/kind-up.sh`.
- [ ] Write them by hand first. Then generate the same thing with **Sloth** or **Pyrra** and diff the output.
      Understanding the difference is the point of the exercise.

### 1.3 Multi-window, multi-burn-rate alerts

Based on the Google SRE Workbook, "Alerting on SLOs". For a 28d window:

| Severity | Long window | Short window | Burn rate | Budget spent when it fires |
|----------|-------------|--------------|-----------|----------------------------|
| page | 1h | 5m | 14.4x | 2.1% |
| page | 6h | 30m | 6x | 5.4% |
| ticket | 1d | 2h | 3x | 10.7% |
| ticket | 3d | 6h | 1x | 10.7% |

(The Workbook's 2%/5%/10% are for a 30d window. Over 28d the same burn rates spend slightly more.)

- [x] Replace `StorefrontCheckoutFailureRateHigh` and `StorefrontCheckoutLatencyHigh` with these alerts.
      Keep the old rules in git history to compare against.
- [x] Add `runbook_url` and `slo` labels and annotations to every alert.
      Done 2026-10-02 in `prometheus/rules/slo-alerts.yml` (kind copy: `k8s/base/slo-alerts.yaml`). There are two alerts
      per SLO with one alertname, `severity=page` and `severity=ticket`, so each SLO gets one runbook. Also added
      `StorefrontApiDown`, because a dead app records no requests and the SLO alerts can't see it. Tests are in
      `prometheus/tests/slo_alerts_test.yml`. They cover a fast outage paging, the page clearing after recovery, a
      slow burn opening a ticket without paging, a healthy system staying quiet, and the scrape-down cases.
      Removing the 5m short window from the fast page makes the recovery test fail.

### 1.4 Alert delivery and runbooks

- [x] Configure Alertmanager routes: `severity=page` goes to a real receiver (Slack webhook, ntfy.sh, or email),
      and `severity=ticket` goes to a quieter channel. Add grouping and an inhibition rule so a page silences
      the matching ticket.
      Done 2026-10-02 for Compose in `alertmanager/alertmanager.yml`: Slack `#alerts-page` and `#alerts-ticket`, with
      webhook URLs in the gitignored `alertmanager/secrets/`, plus a local `alert-logger` that receives everything.
      Inhibitions: a page mutes the matching ticket, and `StorefrontApiDown` mutes all burn alerts. Verified with
      `amtool config routes test`, injected alerts (the same-SLO ticket shows `suppressed`), and a real
      `StorefrontApiDown` from stopping the API.
- [x] Slack webhooks created and the secret files filled in (manual, see `alertmanager/secrets/README.md`).
      Done 2026-10-02: workspace StorefrontSLO, channels `#alerts-page` and `#alerts-ticket`, test alert delivered.
- [x] Same Alertmanager config on kind. kube-prometheus-stack runs its own Alertmanager, so pass this file with
      `--set-file alertmanager.stringConfig=...`, mount the Slack URLs from a Secret
      (`alertmanager.alertmanagerSpec.secrets`), and deploy the logger or drop its receivers there.
- [x] Write `docs/runbooks/<alert>.md` for each alert, covering what it means, first queries to run,
      likely causes (payment provider, DB pool, stockouts, bad deploy), and how to mitigate.
      Five runbooks, one per alertname. Page and ticket share a runbook because diagnosis is the same.
      Stockouts aren't a cause: 409s are excluded from the SLI.
- [x] Add `docs/postmortem-template.md`.

### 1.5 SLO dashboard

- [x] Add a Grafana dashboard with, per SLO: current SLI, budget remaining, burn rate for each window,
      and an annotation for every alert that fired.
      Done 2026-10-02: `grafana/dashboards/slo.json` ("Storefront SLOs"). A row repeats per SLO with the SLI vs.
      objective, budget remaining (status color plus trend), burn rate now for all 7 windows, and burn rate over
      time for the page pairs (same color = same pair, dashed = short window, threshold lines at 6x and 14.4x).
      `ALERTS` annotations mark pages and tickets. A `Budget window` variable switches 28d/1d for the lab.

**Done when:** `promtool test rules` has unit tests proving each burn-rate alert fires (and stays quiet) on
synthetic series, and the SLO dashboard is committed.

**Experiment:** Run the payment outage again (`PAYMENT_FAILURE_RATE=0.3`). Record how long it takes to page
and how much budget is gone at that point. Then try `0.03`, which is a slow burn. The old threshold alert
never fires on it, but the 1d ticket alert does. Write both up using the postmortem template.

- [x] Fast burn (`0.3`): paged after 9 min, 1.54% of the 28d budget spent, page cleared 26 min after recovery.
      [Postmortem](postmortems/2026-10-02-payment-outage-fast-burn.md).
- [x] Slow burn (`0.02`, 4x; `0.03` is exactly the 6x page threshold and would flap): ticket after 9 min in the lab
      (15–16 h with real history, per the promtool scenario), never paged, and the old threshold peaked at 4.8% without
      firing. [Postmortem](postmortems/2026-10-03-payment-slow-burn.md).

---

## Phase 2: Production-shaped Kubernetes

This phase fixes the items in the README's "Known shortcuts" list and adds the controls a real workload has.

### 2.0 Bootstrap (done 2026-10-03)

`scripts/kind-up.sh` creates the cluster and deploys everything in one rerunnable step: 1 control plane plus 3
workers in fake zones, Calico, kube-prometheus-stack 91.9.0 with the shared Alertmanager config, alert logger,
dashboards, app, and SLO rules. Problems found on the way:
- etcd stalled on Docker Desktop's WSL disk (546 slow-disk warnings, 18 s apply times). The API server dropped out
  and kube-state-metrics crash-looped. Fix: `--unsafe-no-fsync` in `kind-config.yaml` (lab only). Kubernetes' own
  `KubeAPIErrorBudgetBurn` SLO alert caught it and sent a ticket.
- The chart's `alertmanager.stringConfig` is ignored unless `tplConfig: true`, and that setting would break the
  Slack templates. So the file is passed as `alertmanager.config`, and the rendered result is checked to be
  identical to `alertmanager/alertmanager.yml`.
- On kind, kube-prometheus-stack's scrapes and alerts for etcd, the scheduler, the controller manager and
  kube-proxy are turned off: kind hides those metrics, so their "Down" alerts would fire forever. Cluster `critical`
  alerts go to the ticket channel, `warning`/`info` to the logger only, and Watchdog is dropped.

### 2.1 Schema and data

- [x] Replace `ddl-auto: update` with **Flyway** migrations, and move catalog seeding into a migration.
      Seeding then runs exactly once, which removes the single-replica restriction.
      Done 2026-10-03. V1 recreates the exact Hibernate schema (from `pg_dump`), and V2 seeds the catalog with stock from a
      placeholder bound to `storefront.restock-level`. `ddl-auto: validate` now fails startup on drift (checked by
      renaming a column: `missing column [price_cents]`). On kind, 3 replicas started together on an empty database:
      one migrated, two waited on Flyway's lock and found it up to date, and there were exactly 8 products.
- [x] Move Postgres off `emptyDir`. Options:
      - A StatefulSet with a PVC teaches the primitives.
      - The **CloudNativePG** operator (recommended) teaches operators and CRDs, and ships a PodMonitor
        and a Grafana dashboard.
      Done 2026-10-04 with CloudNativePG 1.30.1 (chart 0.29.1): a `Cluster` with 2 instances (primary plus an async
      streaming standby, required anti-affinity, a 1Gi PVC each) and a hand-written PodMonitor, because the Cluster's
      `enablePodMonitor` is deprecated. The operator's dashboard is in Grafana. The app uses `storefront-db-rw` with
      the generated `storefront-db-app` Secret, so the database password is no longer in git.

      **Failover experiment** (checkout-stress, 10 VUs, primary pod deleted after 3 min):

      | | default `smartShutdownTimeout` (180s) | `smartShutdownTimeout: 15` |
      |---|---|---|
      | standby chosen | +187s | +23s |
      | new primary accepting writes | +188s | +43s |
      | back to 2 healthy instances | n/a | +78s |
      | failed requests (k6) | 4 of 10,481, all at the cutover | 2 of 9,624, all at the cutover |
      | failed checkouts | 1 | 0 |

      Deleting a pod triggers a "smart" shutdown that waits for sessions to end, but the connection pool never ends
      them, so the default always ran the full 180s before promotion. The old primary kept serving through existing
      connections meanwhile, so users barely noticed, but the cluster spent 3 minutes neither healthy nor failed over.
      With 15s, requests queued on the pool (pending connections peaked at 10) for about 20s instead of failing.
      Replication is async: a failover can lose the last moments of committed writes. Synchronous replication
      would prevent that, but with 2 instances it blocks all writes whenever the standby is down.
      Rerun with `scripts/experiments/exp3-db-failover.sh`.
- [x] **Why checkouts were slow under load on kind** (2026-10-05, checkout-stress at 10 VUs, 5 min, A/B):

      | | default | `synchronous_commit: off` |
      |---|---|---|
      | checkout p50 / p95 / p99 | 175 ms / 2.06 s / 5.3 s | 166 ms / 239 ms / 260 ms |
      | over 500ms | 11.5% | 0.7% |
      | sampled Postgres sessions waiting on WAL / row locks | 147 / 23 | 1 / 0 |

      It was not CPU: nodes were about 15% busy, the pool never queued, and GC was negligible. Docker Desktop's
      virtual disk occasionally stalls a WAL flush for seconds; transactions queue behind it, and so do the
      checkouts waiting on their row locks. The ~170 ms median is by design (the fake payment call is 150 ms).
      EBS on EKS should not show these stalls. The kind overlay now sets `synchronous_commit: "off"` (lab only, like
      etcd's `--unsafe-no-fsync`); `base/` keeps the safe default. Verified through the overlay: p95 238 ms, 1.3%
      over 500ms.
- [ ] **Unexplained rare multi-second stall.** Even without the WAL waits, one request per 5-minute run still takes
      10-15 s, and p99 varied between 260 and 844 ms across runs. The source isn't the WAL and isn't CPU; still to be
      found (candidates: the restock or reservation-sweep jobs, Calico or kube-proxy, a WSL hiccup).
- [ ] **SLI blind spot found during the failover experiment.** Micrometer only creates a `status="500"` series at the
      first 500, and `increase()`/`rate()` ignore a series' first sample. So the first errors of an incident
      can be missing from every availability SLI. In the first failover run, all 4 errors were invisible to the
      SLO queries. Options to investigate: Prometheus' created-timestamp zero injection with OpenMetrics `_created`,
      or pre-registering the error series at startup.

### 2.2 Availability during change

- [ ] Run 3 replicas with a `PodDisruptionBudget` (`minAvailable: 2`) and `topologySpreadConstraints` across nodes.
      Add a third node to `kind-config.yaml`.
- [x] Replace `initialDelaySeconds` with a `startupProbe`. Done 2026-10-03 during bootstrap: on the busy kind
      cluster, startup took 60-70 s and the 40 s liveness delay killed pods 1.4 s after they logged "Started".
- [ ] Set up graceful shutdown: `server.shutdown: graceful`, a short `preStop` sleep, and a matching
      `terminationGracePeriodSeconds`.
- [ ] **Autoscaling.** Start with an HPA on CPU. Then use **KEDA** with a Prometheus trigger on requests/sec,
      so the service scales on the same metrics the SLOs use.

### 2.3 Security baseline

- [ ] Label the namespace for Pod Security Admission `restricted`, and set `securityContext` to match
      (`runAsNonRoot`, `readOnlyRootFilesystem`, drop all capabilities, a `/tmp` emptyDir).
- [ ] Add NetworkPolicies: default-deny, allow API → Postgres, and allow Prometheus → API:8080.
      Note that kind's default CNI **does not enforce NetworkPolicy**. Create the cluster with
      `disableDefaultCNI: true` and install Calico or Cilium, or the policies will silently do nothing.
- [ ] Remove plaintext credentials from git. Use **Sealed Secrets** on kind. Phase 4 moves to External Secrets.

### 2.4 Packaging and ingress

- [x] Restructure `k8s/` as **Kustomize**: a `base/` plus `overlays/kind` and later `overlays/eks`.
      Add `overlays/k3s` in Phase 4a and `overlays/eks` in Phase 4b.
      The numbered-file `kubectl apply` in the README becomes `kubectl apply -k`.
      Done 2026-10-03. `kubectl diff -k` against the running cluster showed only the new `part-of` label, the
      generated rule files are byte-identical, and applying restarted no pods. Third-party software stays on Helm
      (kube-prometheus-stack, and later CloudNativePG, KEDA and Sealed Secrets). Your own app uses Kustomize.
- [ ] Replace port-forwards with ingress-nginx (or Gateway API) on kind, using `extraPortMappings`.

**Done when:** The README's "Known shortcuts" section can be deleted.

**Experiment:** Under k6 load, run `kubectl rollout restart` and delete a node's pods. Compare checkout
error budget spent before and after the graceful shutdown and PDB changes. Ideally the after number is zero.

---

## Phase 3: CI/CD and GitOps

### 3.1 CI (GitHub Actions)

- [ ] On every PR: `mvn verify` (Testcontainers), `promtool check rules` plus `promtool test rules`,
      `kubeconform` on the rendered Kustomize output, and a lint pass (`kube-linter` or `checkov`).
- [ ] On main: build the image, push it to **GHCR** tagged with the git SHA, scan it with **Trivy**
      (fail on HIGH/CRITICAL), generate an SBOM, and sign it with **cosign** (keyless).
- [ ] **Smoke test in CI:** create a kind cluster (`helm/kind-action`), deploy, and run a 2-minute k6 test whose
      `thresholds` mirror the SLOs (`http_req_failed<0.005`, `p(99)<500` on checkout). The pipeline fails
      when the SLO would.

### 3.2 GitOps

- [ ] Install **Argo CD** on the cluster to sync `overlays/kind` from this repo. CI then updates the image tag
      in the overlay instead of running `kubectl`.
- [ ] Manage kube-prometheus-stack and CloudNativePG as Argo CD Applications too
      (app-of-apps), so the whole cluster can be rebuilt from git.

### 3.3 Progressive delivery (capstone)

- [ ] Replace the Deployment with an **Argo Rollouts** `Rollout` using canary steps (20% → 50% → 100%).
- [ ] Add an `AnalysisTemplate` that queries the Phase 1 SLI recording rules for the canary pods only,
      and aborts if the error ratio or burn rate goes over budget.

**Done when:** A merge to main reaches the cluster without anyone running `kubectl`.

**Experiment:** Add a `BUG_MODE` flag that makes a build fail 10% of checkouts with a 500, and ship it.
Argo Rollouts should catch it at 20% and roll back automatically, and the budget spent should be a fraction
of what a full rollout would have cost. This single demo covers SLOs, Kubernetes, and CI/CD together.

---

## Phase 4a: Cloud on k3s (EC2)

Run the system on a real cloud cluster that you operate yourself. k3s on EC2 costs about a third of EKS,
and it makes you handle the parts EKS later takes over: the control plane, node identity, and storage.
Keep a written list of each piece you had to run yourself, because Phase 4b is structured around that list.

- [ ] **Terraform foundation.** State in S3 with locking. Modules for a VPC, security groups, and EC2 instances:
      1 k3s server and 2 agents (t3.medium), installed through `user_data`. Use **SSM Session Manager**
      instead of SSH so port 22 stays closed. Expose the Kubernetes API only to your IP, or reach it
      through an SSM port-forward.
- [ ] **Images.** Pull from **GHCR**, which Phase 3 already publishes to. Using GHCR avoids setting up the ECR
      credential provider on self-managed nodes.
- [ ] **Built-in k3s components.** k3s ships with Traefik, ServiceLB, and local-path storage. Decide whether
      to keep Traefik or disable it and install ingress-nginx for parity with kind. Also note that k3s
      **does** enforce NetworkPolicy through its embedded kube-router, unlike kind, so re-test the Phase 2 policies.
- [ ] **Database.** Run CloudNativePG on local-path storage, with backups to S3 through the operator's
      barman integration. Data on a node's disk is the weak point here, and fixing it is part of Phase 4b.
- [ ] **AWS access from pods.** Self-managed nodes have no per-pod identity. Every pod can reach the node role
      through IMDS. Set the IMDS hop limit to 1 so pods can't use it, and keep **Sealed Secrets** from
      Phase 2 for DB credentials. Write down the limitation, because it's the main reason to move to EKS.
- [ ] **Delivery.** Add `overlays/k3s` and point Argo CD at it. GitHub Actions deploys to AWS through
      **OIDC**, so no long-lived access keys are stored.
- [ ] **Observability.** Run the same kube-prometheus-stack, SLO rules, and dashboards as on kind.
      Add node-exporter alerts for disk and memory, since you now own the nodes.
- [ ] **Cost guardrails.** An AWS Budget alert, `make up` / `make down` targets, and a nightly scheduled
      `terraform destroy`.

**Done when:** `make up` goes from an empty account to a working storefront with SLO dashboards and alerts,
`make down` returns the account to $0 per day, and the "what I had to run myself" list is written.

**Experiment:** Stop the k3s server instance while k6 runs. Workloads keep serving, but nothing can be scheduled,
scaled, or rolled out. Measure the budget spent, then compare it with killing an agent node.
Losing a single control-plane node is the strongest argument for Phase 4b.

---

## Phase 4b: Migrate to EKS (later sprint)

Move from k3s to EKS without spending the error budget. Work through the Phase 4a list and replace
each self-managed piece with the managed equivalent.

| Ran it yourself on k3s | Managed on EKS |
|------------------------|----------------|
| Single k3s server | EKS control plane (multi-AZ, $0.10/hr) |
| EC2 agents in Terraform | Managed node group, or **Karpenter** |
| Node role reachable through IMDS | **EKS Pod Identity** (or IRSA), one role per workload |
| Sealed Secrets | **External Secrets Operator** + AWS Secrets Manager |
| Traefik / ServiceLB | **AWS Load Balancer Controller** (ALB) |
| local-path storage | **EBS CSI driver** with gp3 volumes |
| CloudNativePG on node disk | **RDS Postgres**, or CNPG on EBS. Write up the trade-off. |
| GHCR | ECR, now that pod and node identity make it easy |

- [ ] Add Terraform modules for EKS, node groups/Karpenter, ECR, and RDS, reusing the Phase 4a VPC and state.
- [ ] Add `overlays/eks` as a patch on the same base. The diff between the k3s and EKS overlays is itself
      documentation of what changed.
- [ ] **Cutover plan.** Run both clusters side by side. Argo CD syncs both. Restore the latest CNPG backup
      into the new database, switch writes during a short freeze, and move traffic through weighted DNS
      (Route 53, 10% → 50% → 100%) while watching both clusters' SLO dashboards.
- [ ] Tear down the k3s environment only after a full day on EKS without burn-rate alerts.

**Done when:** Traffic is fully on EKS, the k3s Terraform is removed (or kept as a documented alternative), and the
cutover has a written postmortem-style review, including how much budget it spent.

**Experiment:** Terminate a node, or all nodes in one AZ, while k6 runs. Check whether topology spread, the PDB,
and Karpenter hold the availability SLO without manual steps. Then compare with the Phase 4a control-plane outage.

---

## Phase 5: Deeper reliability (stretch)

Pick items based on interest.

- **Tracing:** Micrometer Tracing → OpenTelemetry Collector → Tempo. Enable **exemplars** so a point on the
  checkout latency histogram links to the trace that caused it.
- **Logs:** Structured JSON logs with trace IDs, shipped to Loki. Wire up one-click navigation from dashboard
  to trace to logs.
- ~~**Fix the deliberate design flaw.**~~ Done early, on 2026-10-01: `CHECKOUT_MODE=saga` reserves, charges,
  then settles or compensates. The old path is kept as `single-tx` for comparison. See Phase 1.1 for the numbers.
- **Resilience:** Resilience4j timeouts, retries with backoff, and a circuit breaker on the payment client,
  each measured against the SLOs.
- **Chaos engineering:** Replace the manual `set env` experiments with **Chaos Mesh** experiments (pod kill,
  network latency to Postgres, CPU stress) stored in git, and run a written game day.
- **Synthetic probing:** blackbox-exporter probing through the ingress, as an outside-in availability SLI
  to compare with the server-side one.

---

## Open decisions

| Decision | Options | Leaning |
|----------|---------|---------|
| Postgres on Kubernetes | StatefulSet vs. CloudNativePG | CloudNativePG |
| Manifest packaging | Kustomize vs. Helm chart | Kustomize (optionally a Helm chart later) |
| SLO tooling | Hand-written vs. Sloth vs. Pyrra | Hand-write first, then adopt Pyrra for its UI |
| GitOps | Argo CD vs. Flux | Argo CD (pairs with Argo Rollouts) |
| Cloud cluster | EKS vs. k3s on EC2 | **Decided:** k3s first (4a), migrate to EKS later (4b) |
| Cloud database on EKS | RDS vs. CloudNativePG on EBS | RDS, as a contrast with k3s |
