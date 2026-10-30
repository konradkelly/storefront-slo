# StorefrontProbeFailing

**Severity:** page. Fires when most synthetic requests in the last 3 minutes failed, and stays true for 2 minutes.
blackbox-exporter fetches `/products/1` through the Gateway every 15 s
([storefront-probe.yaml](../../k8s/monitoring/storefront-probe.yaml)), on kind and k3s.

## What it means

A shopper inside the cluster can't load a product page. The probe counts time, not requests, so it fires when the
SLO alerts can't: when requests hang, when clients slow down to match, or when there is no other traffic. In the
[k3s control-plane stop](../postmortems/2026-10-29-k3s-control-plane-stop.md) the SLIs recorded about 1% of a
12-minute outage. This alert would have fired after about 4 minutes.

It doesn't see the way in from outside the cluster: on k3s, the Elastic IP and the server's ServiceLB. Alertmanager
inhibits it while `StorefrontApiDown` fires.

## First five minutes

1. **Which step fails?** Ask the exporter for one probe with its debug log:
   ```bash
   kubectl -n monitoring port-forward svc/blackbox-prometheus-blackbox-exporter 9115 &
   curl -s 'localhost:9115/probe?module=storefront_product&debug=true&target=http://envoy-gateway-storefront-92f58a48.envoy-gateway-system.svc/products/1'
   ```
   - **503, or connection refused:** Envoy has no ready API pod, or Envoy itself is down.
   - **500, or no answer within 5 s:** the API runs but fails, usually on the database. The API gives up on a
     database connection after 5 s (`spring.datasource.hikari.connection-timeout`).
   - **404:** product 1 no longer exists. That's the probe's target, not an outage. Fix the target.
2. **Are customers affected?** Compare with the SLO dashboard. If the SLIs look healthy while the probe fails, trust
   the probe first: the SLIs only count requests that finish.

## Causes

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| Database unreachable | API logs show `Connection is not available, request timed out after 5000ms` or `UnknownHostException: storefront-db-rw`. | `kubectl -n storefront get cluster storefront-db`: phase, ready instances, current primary. `UnknownHostException` means DNS: `kubectl -n kube-system get pods -l k8s-app=kube-dns`. |
| Control plane down (k3s) | `kubectl` times out. | Check the server instance: `aws ec2 describe-instance-status`. See the [control-plane postmortem](../postmortems/2026-10-29-k3s-control-plane-stop.md). |
| No ready API pod | `kubectl -n storefront get pods -l app=storefront-api`. | See [StorefrontApiDown](StorefrontApiDown.md). |
| Envoy down | `kubectl -n envoy-gateway-system get pods`. | Check the Gateway: `kubectl -n gateway get gateway storefront`. |
| The probe is broken, not the shop | The storefront answers from outside the cluster (`curl http://storefront.localhost/products` on kind, the Elastic IP on k3s). | `kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus-blackbox-exporter` and the exporter's logs. |

## After

Postmortem ([template](../postmortem-template.md)). Estimate the budget spent from the outage's length, not from
the SLIs, which undercount any outage in which requests hang.
