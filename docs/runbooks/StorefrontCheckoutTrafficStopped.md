# StorefrontCheckoutTrafficStopped

**Severity:** page. Fires when no checkout request (`POST /orders`) has arrived for 5 minutes, after more than 100
in the hour before, while shoppers still open the catalog (`GET /products`). Stays true for 2 minutes first.

## What it means

People are in the shop, but nobody gets to checkout. The checkout SLO can't see this: it divides failed checkouts
by checkout attempts, and with no attempts there is nothing to divide. Usually a step before checkout fails, and
shoppers give up before they get there. That's what happened in the
[k3s control-plane stop](../postmortems/2026-10-29-k3s-control-plane-stop.md). Less often, checkout itself is
unreachable, for example after a route change.

Its idea of "normal" is the hour before, so it clears on its own after an hour without checkouts. If it clears and
checkouts haven't come back, the problem is still there. Alertmanager inhibits it while `StorefrontApiDown` fires.

## First five minutes

1. **Is a step before checkout failing?** Look at the catalog and cart rows of the SLO dashboard, or:
   ```
   sum by (uri, status) (rate(http_server_requests_seconds_count{application="storefront-api", uri!~"/actuator.*"}[5m]))
   ```
   - **5xx on `/products` or `/cart`:** follow [catalog](StorefrontCatalogAvailabilityBudgetBurn.md) or
     [cart](StorefrontCartAvailabilityBudgetBurn.md). Database trouble shows up there first.
     [StorefrontProbeFailing](StorefrontProbeFailing.md) usually fires too.
   - **Catalog and cart fine, no `/orders` at all:** is checkout still routed? `kubectl -n storefront get httproute
     storefront-api -o yaml` should list `/orders`. Try a checkout yourself through the Gateway.
2. **Is it a load test?** In the lab, a k6 run that keeps browsing but no longer checks out looks the same (a
   changed `PROFILE` or script). `kubectl -n storefront get jobs`.

## After

Postmortem ([template](../postmortem-template.md)). Count the lost checkouts from the hour before: at its rate,
the outage's length tells you how many orders didn't happen. The checkout SLO recorded none of them.
