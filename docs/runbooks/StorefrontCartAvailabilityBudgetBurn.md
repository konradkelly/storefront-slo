# StorefrontCartAvailabilityBudgetBurn

**SLO:** cart availability, 99.9% of `/cart/**` requests non-5xx over 28 days ([definition](../slo.md#cart-availability-999)).
**Severities:** `page` means the budget is going fast, and `ticket` means a slow leak.

## What it means

Adding to cart (`POST /cart/items`) or viewing a cart (`GET /cart/{cartId}`) is returning 5xx errors.

## Impact

Shoppers who want to buy can't. The checkout SLO won't show this: people who can't fill a cart never
reach checkout, so checkout sees fewer attempts, not more failures. Expect checkout volume to drop at the
same time. That's why cart has its own SLO ([decision](../slo.md#decisions)).

## First five minutes

1. **Still happening, and which endpoint?**
   ```promql
   slo:cart_availability:error_ratio_rate5m
   sum by (uri, method, status) (rate(http_server_requests_seconds_count{uri=~"/cart/.*", status=~"5.."}[5m]))
   ```
2. **Cart only, or everything?** If catalog and checkout are also burning, the cause is shared (database or
   the app). Go to the [catalog runbook](StorefrontCatalogAvailabilityBudgetBurn.md) causes.
3. **Funnel check.** A drop in checkouts confirms the user impact:
   `sum(rate(storefront_checkouts_total[5m]))`

## Likely causes

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| Database write failures | Errors mostly on `POST /cart/items`. App logs show constraint or connection errors. Postgres disk or health problems. | Fix Postgres. Check free disk space and whether it accepts writes. |
| Connection pool exhausted | `hikaricp_connections_pending` > 0. | Reduce load or scale out. |
| Bad deploy | Errors start at the rollout. | `kubectl -n storefront rollout undo deploy/storefront-api`. |

## After

Page: postmortem ([template](../postmortem-template.md)). Include the checkout volume dip as lost revenue.
