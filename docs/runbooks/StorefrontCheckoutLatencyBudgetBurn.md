# StorefrontCheckoutLatencyBudgetBurn

**SLO:** checkout latency, 99% of `POST /orders` under 500ms over 28 days ([definition](../slo.md#checkout-latency-99)).
**Severities:** `page` means the budget is going fast, and `ticket` means a slow leak.

## What it means

Too many checkouts take longer than 500ms. Requests that fail slowly (timeouts) also count as slow.

## Impact

Customers wait at the most sensitive step. Slow checkouts get abandoned and double-submitted, and they often
come before availability failures, because a request that waits long enough turns into a timeout.

## First five minutes

1. **Still happening?**
   ```promql
   slo:checkout_latency:error_ratio_rate5m
   slo:checkout_latency:error_ratio_rate1h
   ```
2. **How slow, and is payment the slow part?** Compare checkout latency with payment latency:
   ```promql
   histogram_quantile(0.99, sum by (le) (rate(http_server_requests_seconds_bucket{uri="/orders", method="POST"}[5m])))
   histogram_quantile(0.99, sum by (le) (rate(storefront_payment_duration_seconds_bucket[5m])))
   ```
   - Checkout p99 ≈ payment p99 + a little: the provider is slow.
   - Checkout p99 much higher than payment p99: requests are waiting on each other (locks or connection pool).
3. **Waiting on the pool?** `hikaricp_connections_pending` and `hikaricp_connections_active`.
4. **Load change?** `sum(rate(http_server_requests_seconds_count{uri="/orders"}[5m]))`

## Likely causes

| Cause | How to confirm | Mitigation |
|-------|----------------|------------|
| Slow payment provider | Payment p99 is close to checkout p99. | In the lab, reset `PAYMENT_LATENCY_MS=150`. In real life, a tighter payment timeout fails fast instead of holding the customer. |
| `CHECKOUT_MODE=single-tx` under load | Checkout p99 is far above payment p99, pool pending stays at 0, and the mode is single-tx. Row locks are held across the payment call, so same-product checkouts queue. | Set `CHECKOUT_MODE=saga`. Background: [architecture/checkout.md](../architecture/checkout.md). |
| Connection pool exhausted | `hikaricp_connections_pending` > 0. | Reduce load or scale out. Check for slow queries in Postgres. |
| Cold start after a deploy | The burn lines up with a rollout and fades within a few minutes. | Usually nothing to do. If it pages on every deploy, add warm-up or a readiness delay (Phase 2 probes). |
| CPU starvation | `rate(process_cpu_usage[5m])` near the limit, or container CPU throttling (kind: `container_cpu_cfs_throttled_periods_total`). | Raise the CPU limit or scale out. |

## After

Page: postmortem ([template](../postmortem-template.md)). Ticket: find out what changed in the last day,
because slow latency burns are usually a capacity or dependency trend.
