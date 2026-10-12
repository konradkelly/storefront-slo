# Monitoring secrets (gitignored)

Only this README is committed.

## grafana-cloud.env

Lets the k3s cluster's Prometheus copy its key metrics to Grafana Cloud (`k8s/monitoring/kps-remote-write.yaml`),
so they survive `make down`. Without this file, `make up` still works and the metrics stay in the cluster.

1. Create a free Grafana Cloud account and stack.
2. **Connections → Add new connection → Hosted Prometheus metrics**, or the stack's **Prometheus → Details** page.
   It shows the remote-write URL and the username (a number).
3. Create an **access policy token** with the `metrics:write` scope only. Prometheus never needs to read.
4. Write the file:

   ```
   GRAFANA_CLOUD_PROM_URL=https://prometheus-prod-XX-prod-us-east-0.grafana.net/api/prom/push
   GRAFANA_CLOUD_PROM_USER=1234567
   GRAFANA_CLOUD_TOKEN=glc_...
   ```

5. Run `make up` (or rerun it on a running cluster). It creates the `grafana-cloud` Secret and enables remote write.

To view the data, import `grafana/dashboards/storefront.json` and `slo.json` into the Grafana Cloud stack
(Dashboards → New → Import) and pick its Prometheus data source; both dashboards use a `datasource` variable.
Every series carries `cluster="k3s-aws"`.
