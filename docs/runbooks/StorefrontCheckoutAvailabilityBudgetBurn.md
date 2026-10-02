# StorefrontCheckoutAvailabilityBudgetBurn

**SLO:** checkout availability, 99.5% over 28 days ([definition](../slo.md#checkout-availability-995)).
**Severities:** `page` means the budget is going fast (at 14.4x it's gone in under 2 days). `ticket` means a slow
leak that will empty the budget before the window ends if nobody fixes it.

## What it means

Too many checkouts are failing because of us. Two things count as failures:

- `POST /orders` returned a **5xx** (an unhandled exception: DB timeout, bug).
- The payment step failed (**402**, `storefront_checkouts_total{status="payment_failed"}`).

Out of stock (409) and bad requests (400) don't count, so a stockout can't cause this alert.

## Impact

Customers try to pay and can't. This is lost revenue. Some of them retry, which adds load.

## First five minutes

1. **Is it still happening?** Compare the short and long windows:
   ```promql
   slo:checkout_availability:error_ratio_rate5m
   slo:checkout_availability:error_ratio_rate1h
   ```
   If 5m is back near 0, the incident is over and the alert will clear by itself. Write it up anyway.
2. **Payment or us?** Split the bad events by source:
   ```promql
   sum(rate(storefront_checkouts_total{status="payment_failed"}[5m]))
   sum by (status) (rate(http_server_requests_seconds_count{uri="/orders", status=~"5.."}[5m]))
   ```
3. **Did something just change?** Check recent deploys and config changes:
   `kubectl -n storefront rollout history deploy/storefront-api`, or `docker compose ps` for container ages.
4. **How much budget is left?** `slo:checkout_availability:error_budget_remaining`

## Likely causes

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| Payment provider failing | `payment_failed` rate is high. `storefront_payment_duration_seconds_count{outcome="failure"}` is rising. | In this lab, check `PAYMENT_FAILURE_RATE` on the deployment (`kubectl -n storefront get deploy storefront-api -o yaml \| grep -A1 PAYMENT`) and reset it to `0.001`. In real life, check the provider's status page, and fail over or degrade if possible. |
| Database trouble (5xx) | 5xx on `/orders`. `hikaricp_connections_pending` > 0, `hikaricp_connections_timeout_total` rising. Postgres pod not Ready. | Restore Postgres (`kubectl -n storefront get pods`, `docker compose ps postgres`). If the pool is exhausted under load, scale out or reduce load first. |
| Bad deploy | Errors start at the rollout time. App logs show exceptions. | Roll back: `kubectl -n storefront rollout undo deploy/storefront-api`. |
| Checkout mode change | `CHECKOUT_MODE=single-tx` was set. It mostly hurts latency, but under heavy contention lock waits can turn into timeouts. | Set `CHECKOUT_MODE=saga`. See [architecture/checkout.md](../architecture/checkout.md). |

## After

- If the page fired, write a postmortem ([template](../postmortem-template.md)), including how much budget was spent.
- If the budget is below 0, freeze risky changes to checkout until it recovers.
