# StorefrontSLO

A small ecommerce API (Spring Boot + Postgres) instrumented with Micrometer, for learning
Prometheus and Grafana on Kubernetes. A fake payment provider with tunable latency and failure
rate lets you break things on purpose and watch the dashboards and alerts react.

## Layout

```
app/          Spring Boot API (products, cart, checkout, fake payments)
k8s/          kind config, Postgres, API, ServiceMonitor, SLO rules and alerts, k6 load Job
prometheus/   Compose scrape config, SLO recording rules, burn-rate alerts, promtool tests
alertmanager/ routing, inhibition, Slack template, local webhook logger (secrets are gitignored)
scripts/      gen-k8s-rules.sh: wraps the SLO rules and alerts into PrometheusRules for kind
loadtest/     k6 script: realistic browsing (default) or checkout-heavy stress
docs/         SLO spec, runbooks, postmortem template, roadmap, architecture notes
```

## API

| Method | Path              | Body                                  |
|--------|-------------------|---------------------------------------|
| GET    | /products         |                                       |
| GET    | /products/{id}    |                                       |
| POST   | /cart/items       | `{"cartId","productId","quantity"}`   |
| GET    | /cart/{cartId}    |                                       |
| POST   | /orders           | `{"cartId"}` (201, 402, or 409)       |

## Metrics

Free from Spring Boot: `http_server_requests_seconds_*` (tagged by `uri`, `method`, `status`),
JVM, and HikariCP pool metrics.

Custom (see `StorefrontMetrics.java`):

| Prometheus name                         | Type      | Labels    |
|-----------------------------------------|-----------|-----------|
| `storefront_checkouts_total`                  | counter   | `status`: success, payment_failed, out_of_stock |
| `storefront_cart_items_added_total`           | counter   |           |
| `storefront_order_value_dollars_sum/_count`   | summary   |           |
| `storefront_payment_duration_seconds_bucket`  | histogram | `outcome` |
| `storefront_reservations_expired_total`       | counter   | (stock reservations released because checkout never finished) |

## Step 1: run locally with Docker Compose

```bash
docker compose up --build
curl localhost:8080/products
curl -X POST localhost:8080/cart/items -H 'Content-Type: application/json' \
  -d '{"cartId":"c1","productId":1,"quantity":2}'
curl -X POST localhost:8080/orders -H 'Content-Type: application/json' -d '{"cartId":"c1"}'
curl -s localhost:8080/actuator/prometheus | grep storefront_
```

Read the raw `/actuator/prometheus` output before moving on. Knowing what a counter,
histogram bucket, and `_sum`/`_count` pair look like makes PromQL much easier.

Prometheus is on `localhost:9090`, and Grafana is on `localhost:3000` (admin/admin) with the
**Storefront > Storefront API** dashboard already provisioned. Alertmanager is on `localhost:9093`. It routes
`severity=page` to Slack `#alerts-page` and `severity=ticket` to `#alerts-ticket` (setup:
[alertmanager/secrets/README.md](alertmanager/secrets/README.md)). It also sends every notification to a local
logger, so you can follow routing without Slack:

```bash
docker compose logs -f alert-logger
```

Each alert links to its runbook in [docs/runbooks/](docs/runbooks/). To put traffic on it:

```bash
docker compose --profile load run --rm k6
```

Tests run the app against a real Postgres through Testcontainers, so Docker must be running:

```bash
cd app && mvn verify
```

The SLO recording rules and burn-rate alerts ([docs/slo.md](docs/slo.md)) live in `prometheus/rules/`. Compose
loads them directly. After editing them, run the unit tests and regenerate the kind copies:

```bash
docker run --rm -v "$PWD/prometheus:/src" -w /src --entrypoint promtool prom/prometheus:v3.15.0 test rules tests/slo_test.yml tests/slo_alerts_test.yml
sh scripts/gen-k8s-rules.sh
```

On Git Bash for Windows, prefix the `docker run` with `MSYS_NO_PATHCONV=1` and use `$(pwd -W)` in place of `$PWD`.

## Step 2: deploy to kind

```bash
kind create cluster --config k8s/kind-config.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace

docker build -t storefront-api:dev ./app
kind load docker-image storefront-api:dev --name storefront

kubectl apply -f k8s/00-namespace.yaml -f k8s/10-postgres.yaml
kubectl -n storefront rollout status deploy/postgres
kubectl apply -f k8s/20-storefront-api.yaml -f k8s/30-servicemonitor.yaml \
  -f k8s/41-slo-rules.yaml -f k8s/42-slo-alerts.yaml
kubectl -n storefront rollout status deploy/storefront-api

# The kube-prometheus-stack Grafana sidecar loads ConfigMaps labeled grafana_dashboard=1.
kubectl -n monitoring create configmap storefront-dashboard --from-file=grafana/dashboards/storefront.json
kubectl -n monitoring label configmap storefront-dashboard grafana_dashboard=1

kubectl -n storefront create configmap k6-script --from-file=loadtest/checkout.js
kubectl apply -f k8s/50-k6-job.yaml
```

Open the UIs:

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090          # Prometheus
kubectl -n monitoring port-forward svc/kps-grafana 3000:80               # Grafana (admin)
kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d
kubectl -n monitoring port-forward svc/alertmanager-operated 9093        # Alertmanager
```

In Prometheus, check **Status > Targets** for `serviceMonitor/storefront/storefront-api`. If it is missing,
the `release: kps` label on the ServiceMonitor is the first thing to check.

## Step 3: build the dashboard yourself

A finished version lives in `grafana/dashboards/storefront.json`, but building the panels yourself is
the fastest way to learn PromQL. Starter queries (paste into Grafana panels):

| Panel                       | PromQL |
|-----------------------------|--------|
| Requests/sec by endpoint    | `sum by (uri) (rate(http_server_requests_seconds_count{application="storefront-api"}[1m]))` |
| p95 checkout latency        | `histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{uri="/orders",method="POST"}[5m])))` |
| Checkout outcomes/sec       | `sum by (status) (rate(storefront_checkouts_total[1m]))` |
| Checkout failure ratio      | `sum(rate(storefront_checkouts_total{status!="success"}[5m])) / sum(rate(storefront_checkouts_total[5m]))` |
| Revenue per minute          | `sum(rate(storefront_order_value_dollars_sum[5m])) * 60` |
| Average order value         | `sum(rate(storefront_order_value_dollars_sum[5m])) / sum(rate(storefront_order_value_dollars_count[5m]))` |
| p95 payment latency         | `histogram_quantile(0.95, sum by (le) (rate(storefront_payment_duration_seconds_bucket[5m])))` |
| DB pool active / pending    | `hikaricp_connections_active` and `hikaricp_connections_pending` |
| Pod restarts                | `kube_pod_container_status_restarts_total{namespace="storefront"}` |

When your dashboard looks right, compare it with the committed one.

## Step 4: experiments

Each `set env` triggers a rollout. Predict what you'll see before running it.

1. **Payment outage.** `kubectl -n storefront set env deploy/storefront-api PAYMENT_FAILURE_RATE=0.3`
   The 5m burn rate jumps to about 60x right away, but `StorefrontCheckoutAvailabilityBudgetBurn` (severity page)
   waits until the 1h window passes 14.4x as well, about 15 minutes in. Set it back to 0.001 within half an
   hour and the page clears within about 5 minutes, because the 5m window recovers first. A longer outage also
   trips the 6h/30m pair, which takes up to 30 minutes to clear. Watch it on Prometheus's Alerts page.
2. **Slow provider, two checkout designs.** `kubectl -n storefront set env deploy/storefront-api PAYMENT_LATENCY_MS=1500`
   Checkout p95 climbs with payment latency. Now repeat with `CHECKOUT_MODE=single-tx`, which calls
   payment inside the DB transaction. Each checkout keeps its product rows locked for the whole payment,
   so carts sharing a product queue behind each other, and checkout latency grows well past payment latency.
   The default `saga` mode reserves stock, commits, charges, then settles or returns the stock, so locks
   last milliseconds. Explaining the difference is a great interview answer. In Compose:
   `CHECKOUT_MODE=single-tx docker compose up -d storefront-api`. Then load it with
   `docker compose --profile load run --rm --no-deps -e PROFILE=checkout-stress -e VUS=30 k6`. Without `--no-deps`, `run` recreates
   the API with the default mode. Diagrams and trade-offs: [docs/architecture/checkout.md](docs/architecture/checkout.md).
3. **Stockouts.** `kubectl -n storefront set env deploy/storefront-api RESTOCK_LEVEL=20`
   The `out_of_stock` series grows between restocks.
4. **Scale out.** `kubectl -n storefront scale deploy/storefront-api --replicas=3`
   Watch per-pod series appear and notice why dashboard queries use `sum by`.
5. **Kill a pod.** `kubectl -n storefront delete pod -l app=storefront-api --wait=false`
   Look for the gap in the graphs and the scrape target going down.

Reset with `PAYMENT_FAILURE_RATE=0.001 PAYMENT_LATENCY_MS=150 RESTOCK_LEVEL=200 CHECKOUT_MODE=saga`.

## Known shortcuts (fine for learning, not for production)

- Postgres uses an emptyDir, so data is lost when its pod restarts.
- `ddl-auto: update` manages the schema; a real app would use Flyway or Liquibase.
- The API starts at one replica because catalog seeding is not safe to run concurrently.
- Credentials are plain values in a Secret manifest.
