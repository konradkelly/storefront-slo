# Postmortem: payment provider outage on k3s (soak drill, fast burn)

| | |
|---|---|
| Date | 2026-10-27 |
| Authors | Konrad Kelly |
| Status | draft |
| Severity | page |
| SLOs affected | checkout-availability |
| Duration | 20 min of failing checkouts (16:01:30 to 16:21:45 UTC) |
| Time to detect | 13m 45s to the page in Prometheus, Slack 5 seconds later |
| Time to mitigate | 5m 50s from the page to the fix (scripted), impact ended 40 seconds after that |

This was a planned drill, the second half of the Phase 4a soak on k3s ([docs/k3s.md](../k3s.md)), run unattended
by `scripts/experiments/soak_drill.py`. It repeats the [Phase 1 fast-burn experiment](2026-10-02-payment-outage-fast-burn.md)
on a cluster with 2.5 days of history. It ran a day after the [slow burn](2026-10-26-k3s-soak-slow-burn.md): far
enough for the 6h and 1d windows to be clean again, but not the 3d window, which matters below.

## Summary

From 16:01:30 the simulated payment provider failed 30% of charges. `StorefrontCheckoutAvailabilityBudgetBurn`
paged after 13m 45s through the 1h & 5m pair. The drill set the rate back 6 minutes later, and the page resolved
5 minutes after that. A ticket followed: the 3d window still held the previous day's slow burn, and the ticket
reached Slack 4 minutes before the page's RESOLVED message.

## Impact

- **Users:** 59 of 227 checkout attempts failed with 402 (26%) over about 21 minutes, including the rollouts in and
  out. Before the page, it was 47 of 158 (30%).
- **Error budget:** at 10.6 checkouts/min the 28d budget is about 2,137 failed checkouts. The outage spent **2.8%**
  of it, and **2.2%** was gone when the page fired. With the slow burn, the two drills spent 6.8%. The whole 72-hour
  soak, baseline included, spent 8.8% (188 failures).
- The dashboard's 1d budget dropped from 80% to −4.5% in 21 minutes.

![Checkout availability, 6 hours to 17:17: the 5m window spikes to about 75x, the 1h window passes the 14.4x page
line, and the 6h window stays near 3.5x](img/2026-10-27-fast-burn-6h.png)

*Six hours to 17:17. The blue 1h line crosses the upper dashed 14.4x line together with the dashed 5m line, which
peaks near 75x. The solid orange 6h line stays near 3.5x, under its 6x line, so only the 1h & 5m pair fires.*

## Timeline (UTC)

| Time | Event |
|------|-------|
| 16:00:04 | Trigger: the drill sets `PAYMENT_FAILURE_RATE=0.30` as an override on the Argo CD Application |
| 16:01:30 | First user impact |
| 16:02:04 | Rollout complete, every API pod at 30% |
| 16:15:15 | Page condition true in Prometheus through the 1h & 5m pair: 1h at 15.5x, 5m at 62x (6h at 2.8x) |
| 16:15:20 | **Page** delivered to #alerts-page, "15.5x" |
| 16:21:05 | Mitigation: the drill removes the override, 5m 50s after the page |
| 16:21:45 | Last failed checkout, from a pod being replaced |
| 16:21:45 | Ticket condition true through the 3d & 6h pair (3d at 1.01x). Held back: the page inhibits it |
| 16:23:05 | Rollout complete |
| 16:26:30 | Page resolves in Prometheus: the 5m window is back under 14.4x |
| 16:26:40 | **Ticket** delivered to #alerts-ticket, now that the page no longer inhibits it |
| 16:30:20 | RESOLVED delivered to #alerts-page (after the 5-minute group interval) |
| 17:00:30 | Ticket resolves in Prometheus |
| 17:01:40 | RESOLVED delivered to #alerts-ticket |

## Detection

**Production-like this time.** Prometheus had 2.5 days of history, so the 6h window really held 6 hours. The page
came through the 1h & 5m pair: at 30% failures (60x), the 1h window passes 14.4x after about 14.4 minutes, and it
took 13m 45s. In Phase 1 the lab paged after 9 minutes, through the 6h & 30m pair, only because its "6h" window
held 70 minutes. That postmortem predicted about 19 minutes for the 1h pair at its 23% failure rate, which fits this
result.

**The 6h & 30m pair never fired.** The 6h window peaked at 3.5x. At 30% failures it takes about 36 minutes of outage
to lift the 6h window past 6x, and this one lasted 20.

**The page cleared quickly.** It resolved 5m 25s after mitigation, as soon as the 5m window had emptied. In Phase 1
it stayed up 26 minutes after recovery, because the 6h & 30m pair was holding it. The runbook's warning that a page
can stay up to 30 minutes after mitigation still applies to outages long enough to fire that pair, not to this one.

**The ticket after the page.** The ticket condition became true 40 seconds after mitigation, through the 3d & 6h
pair. The 6h window held this outage (3.5x), and the 3d window held it plus the previous day's slow burn (1.01x). By
the budget math that's correct: over three days, the budget had been spent faster than sustainable. But Alertmanager
delivered it 10 seconds after the page stopped inhibiting it, and 4 minutes before the page's RESOLVED reached
Slack. In Slack, the order was page at 16:15, ticket at 16:26, page resolved at 16:30. A responder could easily
read the ticket as a second problem, when it's the budget cost of the one they had just fixed.

## Root cause and trigger

The trigger was an injected configuration change: the payment provider failed 30% of charges, simulating a
provider outage. As in Phase 1, checkout depends on the provider directly, with no retry or fallback, so every
failed charge reaches the user as a 402.

## Resolution

The drill removed the override, and Argo CD rolled the API back to the git value (0.1%). Failures stopped 40 seconds
later, once the last old pod was gone, and the rollout finished at 16:23:05.

## What went well

- The page reached Slack 5 seconds after the condition held, with the burn rate and the runbook link.
- The 1h & 5m pair fired on its own, as the design intends for a sharp outage. Nothing depended on short lab history.
- The page cleared about 5 minutes after mitigation, so the alert's state matched reality.
- The two rollouts, at injection and at mitigation, cost no latency budget. Checkout latency stayed at 100%, unlike
  the cold-start latency page in Phase 1. Over the whole soak, k6 saw 1 failed request in 4.26 million.

## What went poorly

- The ticket arrived before the page's RESOLVED and looked like a second incident.
- 2.2% of the 28-day budget was gone before anyone was told. That is the designed cost of the 1h window for a 30%
  outage at this traffic level. Phase 1 noted that a plain threshold alert would page sooner on outages this large.

## Where we got lucky

The load generator was the weakest part of the soak. k6's memory grew for the whole run, and its node fell to 7.8%
free memory at 05:20 on Oct 28. If k6 had been killed during a burn, checkout traffic would have stopped and the SLO
ratios would have had nothing to divide. No SLO alert can fire on that, and the drill would have reverted only at
its 60-minute timeout. This drill ran 13 hours before that low point. Fixed in `cf74166`.

## Action items

| Action | Type | Owner | Tracking |
|--------|------|-------|----------|
| Runbook: a ticket that arrives just after a page usually means the 3-day budget, not a new incident. Check the 3d window and recent incidents first | mitigate | | |
| Make the ticket say which window pair fired (for example, two ticket rules with a `window` label), so a ticket after an incident reads as a 3-day budget alert | detect | | |
| Alert when checkout traffic drops to zero: an empty SLO ratio can't burn budget, so no SLO alert notices | detect | | |
| Stop k6 growing during long runs: summary and thresholds off, metrics pushed to Prometheus | prevent | | done in `cf74166` |
| Add a fallback payment provider or a retry policy (carried over from Phase 1) | prevent | | |
