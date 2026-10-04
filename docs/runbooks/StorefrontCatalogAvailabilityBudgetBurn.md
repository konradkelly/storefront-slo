# StorefrontCatalogAvailabilityBudgetBurn

**SLO:** catalog availability, 99.9% of `/products*` requests non-5xx over 28 days ([definition](../slo.md#catalog-availability-999)).
**Severities:** `page` means the budget is going fast, and `ticket` means a slow leak.

## What it means

Product listing and product pages are returning 5xx errors. 404s for unknown products don't count.

## Impact

This is the top of the funnel. Shoppers can't browse, so nobody reaches cart or checkout. With a 0.1%
budget (about 40 minutes of full outage per 28 days), even short incidents matter.

## First five minutes

1. **Still happening, and which endpoint?**
   ```promql
   slo:catalog_availability:error_ratio_rate5m
   sum by (uri, status) (rate(http_server_requests_seconds_count{uri=~"/products.*", status=~"5.."}[5m]))
   ```
2. **Is it only the catalog?** Check the other SLOs at the same time. If cart and checkout are failing too, the
   cause is shared (database or the app itself), not catalog code.
   ```promql
   slo:cart_availability:error_ratio_rate5m
   slo:checkout_availability:error_ratio_rate5m
   ```
3. **Database health:** Postgres pod/container status, `hikaricp_connections_pending`,
   `hikaricp_connections_timeout_total`.

## Likely causes

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| Postgres down or failing over | All SLOs burning at once. App logs show connection errors. `kubectl -n storefront get cluster storefront-db` shows a phase other than "Cluster in healthy state", or a new current primary. | CloudNativePG promotes the standby by itself. Wait for the phase to return to healthy, then confirm errors stop. If no instance becomes ready, check `kubectl -n storefront describe cluster storefront-db` and the operator logs in `cnpg-system`. Data lives on persistent volumes, so a restart doesn't lose it. |
| Connection pool exhausted | `hikaricp_connections_pending` > 0 and timeouts rising. | Reduce load or scale out. Look for slow or blocked queries. |
| Bad deploy | Errors start at the rollout. | `kubectl -n storefront rollout undo deploy/storefront-api`. |
| Some replicas unhealthy | Errors come from one `instance`/`pod` (`sum by (instance) (...)`). | Delete the bad pod. Phase 2's readiness probes take it out of rotation automatically. |

## After

Page: postmortem ([template](../postmortem-template.md)).
