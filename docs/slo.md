# Storefront SLOs

What "reliable enough" means for the storefront, and how each number is measured. The recording
rules ([prometheus/rules/slo.yml](../prometheus/rules/slo.yml)) and burn-rate alerts
([prometheus/rules/slo-alerts.yml](../prometheus/rules/slo-alerts.yml)) are built from the definitions here,
so change this file first.

## Summary

All windows are 28 days, rolling. 28 days always contains exactly 4 weekends, so a busy Saturday
doesn't move in and out of the window the way it would with 30 days.

| SLO | SLI (good / valid) | Target | Error budget | Same as a full outage of |
|-----|--------------------|--------|--------------|--------------------------|
| Checkout availability | checkouts that did not fail because of us / checkout attempts | 99.5% | 0.5% | 3h 22m |
| Checkout latency | `POST /orders` served in < 500ms / `POST /orders` | 99% | 1% | 6h 43m |
| Catalog availability | `/products*` non-5xx / `/products*` | 99.9% | 0.1% | 40m |
| Cart availability | `/cart/**` non-5xx / `/cart/**` | 99.9% | 0.1% | 40m |

Catalog latency is deferred until there's a measured baseline to set it against.

## Definitions

`[W]` stands for the window (5m, 1h, 28d, ...). Every SLI is `1 - bad/valid`, or `good/valid`.
The queries below are trimmed for reading. The real rules in
[prometheus/rules/slo.yml](../prometheus/rules/slo.yml) also filter on `application="storefront-api"`, so another
service's `http_server_requests` metrics in the same Prometheus can't leak into these SLIs.

The `or vector(0)` on 5xx terms matters. Micrometer creates a `status="500"` series only after the first 500.
Until then, `sum()` over it returns nothing rather than 0, and `nothing + x` is also nothing, so a healthy
service would show "no data" instead of a 0% error ratio.

### Checkout availability (99.5%)

The user tried to pay and we didn't take their order.

| Outcome | HTTP | Counts as | Why |
|---------|------|-----------|-----|
| success | 201 | good | |
| payment_failed | 402 | **bad** | `FakePaymentService` simulates the provider being down, not a declined card. The user sees a broken checkout either way. |
| unhandled error (DB timeout, bug) | 5xx | **bad** | |
| out_of_stock | 409 | excluded | A business outcome, not a reliability failure. |
| empty cart, missing cartId | 400 | excluded | The client's mistake. |

Excluded outcomes are left out of the denominator as well as the numerator. Counting them as good would
make the SLO look *better* during a stockout spike.

```promql
# bad
  (sum(rate(http_server_requests_seconds_count{uri="/orders", method="POST", status=~"5.."}[W])) or vector(0))
+ sum(rate(storefront_checkouts_total{status="payment_failed"}[W]))
# valid
  sum(rate(http_server_requests_seconds_count{uri="/orders", method="POST", status!~"400|409"}[W]))
```

Two sources are needed: an unhandled exception becomes a 500 before `OrderController` increments
`storefront_checkouts_total`, so the business counter alone would miss it.

Accepted risk: a bug that wrongly returns 400 or 409 is invisible to this SLO.

### Checkout latency (99%)

The user didn't wait more than half a second for checkout. 400s are excluded because they return before
doing any work and would pad the good count. Slow failures (timeouts) count as bad, which they should.

```promql
# good
  sum(rate(http_server_requests_seconds_bucket{uri="/orders", method="POST", status!="400", le="0.5"}[W]))
# valid
  sum(rate(http_server_requests_seconds_count{uri="/orders", method="POST", status!="400"}[W]))
```

This needs an exact 0.5s histogram bucket. Micrometer's defaults jump from 0.447s to 0.537s, so
`application.yml` adds boundaries at 100ms, 300ms, 500ms and 1s.

Baseline (2026-10-01, `checkout-stress` profile, 30 users): saga 100% under 0.5s, single-tx 95.6%.
Single-tx would burn this budget at 4.4×, which is the Phase 1 experiment. See
[architecture/checkout.md](architecture/checkout.md).

### Catalog availability (99.9%)

```promql
# bad
  sum(rate(http_server_requests_seconds_count{uri=~"/products.*", status=~"5.."}[W])) or vector(0)
# valid
  sum(rate(http_server_requests_seconds_count{uri=~"/products.*"}[W]))
```

### Cart availability (99.9%)

```promql
# bad
  sum(rate(http_server_requests_seconds_count{uri=~"/cart/.*", status=~"5.."}[W])) or vector(0)
# valid
  sum(rate(http_server_requests_seconds_count{uri=~"/cart/.*"}[W]))
```

For catalog and cart, 4xx (bad input, unknown product) counts as good: it's the client's mistake, and the
service answered correctly.

## Decisions

**Payment failure rate defaults to 0.1%.** It used to be 2%. Against a 0.5% budget, a healthy system
would burn at 4× forever, the slow-burn ticket would never clear, and the SLO would be ignored. At 0.1%
a healthy system burns about 0.2×. Raise `PAYMENT_FAILURE_RATE` on purpose to simulate a provider outage.

**Catalog and cart are separate SLOs.** Cart failures don't show up in the checkout SLO: a user who can't
add to cart never reaches checkout, so checkout sees fewer attempts rather than more failures. Cart
therefore needs its own coverage. A combined "shopping" SLO would mean half the alerts and runbooks, but
the `browse` profile sends about 15 catalog requests per cart request (2,816 vs. 187 in a 2-minute run).
Mixed together, a cart error rate would be diluted about 15×, and a partial cart outage would barely move
the combined SLI.
*Revisit if* the cart's share of traffic rises above ~30%, the way it did in the old load profile at about
1:1. At that point, combining them would lose little.

**Catalog latency is deferred.** Pick a target after measuring a baseline with the `browse` profile.
Guessing a target means either constant alerts or an SLO that never fires.

## Traffic profiles

Targets and baselines are only meaningful together with the traffic they were measured under.
[loadtest/checkout.js](../loadtest/checkout.js) has two profiles:

| Profile | Shape | Use for |
|---------|-------|---------|
| `browse` (default) | 4–9 catalog views per session, 15% add to cart, half of those check out | SLO baselines and everyday traffic |
| `checkout-stress` | every session fills a cart, 70% check out | saga vs. single-tx latency experiment (needs concurrent checkouts) |

## Baselines

2026-10-02, Docker Compose on a laptop, `browse` profile, 30 users for 5 minutes after a 30s warm-up, saga,
0.1% payment failure rate. 7,320 requests, 69 checkouts.

| SLO | Measured | Budget |
|-----|----------|--------|
| Checkout availability | 0 bad of 69 | within |
| Checkout latency | 1 of 69 over 0.5s (1.4%, max 635ms), in the first 1.5 minutes | over, but see below |
| Catalog availability | 0 bad | within |
| Cart availability | 0 bad | within |
| Catalog latency (no SLO yet) | p50 1.6ms, p95 3.1ms, p99 5.4ms, 100% under 100ms | n/a |

69 checkouts is too few to judge a 99% target, because one slow request moves the ratio by 1.4 points.
The slow one came early, and the warm-up produced only a couple of checkouts, so it was probably the
checkout path still warming up. Rerun for 30+ minutes before treating checkout latency as a real
problem. Catalog latency has huge headroom: a future SLO of 99% under 100ms would only catch real
regressions.

## Known gaps

- **Low checkout volume.** `browse` at 30 users produces about 12 checkouts per minute. In a 5-minute
  window, one failed checkout is about 1.7% errors. The multi-window alerts handle this, because a page
  also needs the 1h window to agree. A real low-traffic service might add synthetic checkouts.
- **Server-side measurement only.** These SLIs come from the app's own metrics. If the app is down, or a
  request never reaches it, nothing is recorded and the ratios go quiet instead of red.
  `StorefrontApiDown` covers the case where Prometheus can't scrape the app at all. It doesn't catch failures in
  front of the app (ingress, DNS). That needs a probe from outside, such as blackbox_exporter.
- **Changing an SLI's inputs corrupts its long windows.** When the 0.5s bucket was added, checkouts
  recorded before it existed still counted as valid but could never count as good. The 28d window read
  98% slow until that data aged out, and old 2% payment failures kept the availability budget negative
  too. In production, annotate the change and expect a skewed budget for one window length. In the lab,
  start Prometheus with empty storage (`docker compose rm -sfv prometheus`).
- **28 days on a lab cluster.** kind never accumulates 28 days of data. Keep 28d as the spec, and add a
  1d dashboard view so budget burn is visible during an afternoon of experiments.
