# Postmortem: payment provider slow burn on k3s (soak drill)

| | |
|---|---|
| Date | 2026-10-26 |
| Authors | Konrad Kelly |
| Status | draft |
| Severity | ticket |
| SLOs affected | checkout-availability |
| Duration | 6h 43m of degraded checkout (08:01:45 to 14:44:52 UTC) |
| Time to detect | 6h 12m to the ticket in Prometheus, 6h 24m to Slack |
| Time to mitigate | 30 min from the ticket to the fix (the drill's stand-in for someone picking up the ticket), 1 min to roll out |

This was a planned drill, part of the Phase 4a soak on k3s ([docs/k3s.md](../k3s.md)). The in-cluster drill
(`scripts/experiments/soak_drill.py`) injected the fault and remediated it with nobody watching. It repeats the
[Phase 1 slow-burn experiment](2026-10-03-payment-slow-burn.md), but on a cluster with a day of steady traffic behind
it (about 10.6 checkouts a minute) instead of a freshly emptied Prometheus.

## Summary

From 08:01:45 the simulated payment provider failed 2% of charges, 4x the rate the 0.5% budget can sustain.
`StorefrontCheckoutAvailabilityBudgetBurn` opened a **ticket** after 6h 12m and never paged, even though the 30m
window spent 59 minutes above the page threshold. The drill set the rate back 30 minutes after the ticket, and the
ticket resolved 71 minutes after that.

## Impact

- **Users:** 86 of 4,214 checkout attempts failed with 402 (2.04%) over 6h 43m. About 4 of those would have failed
  anyway at the normal 0.1%.
- **Error budget:** at 10.6 checkouts/min, the 28d budget is about 2,137 failed checkouts. The burn spent **4.0%**
  of it, and **3.8%** (82 failures) was gone when the ticket fired.
- Projected: at 2% indefinitely, the whole 28d budget would be gone in about 7 days, as in Phase 1.
- The dashboard's 1d budget read −28.6% at mitigation. That panel shows the lab's 1-day view; use the 28d figure
  above.

![Checkout availability over the 24 hours to mitigation: the 30m window (dashed orange) repeatedly crosses the 6x
page line while the 6h window (solid orange) stays near 4x](img/2026-10-26-slow-burn-24h.png)

*The 24 hours up to mitigation. The dashed orange 30m line crosses the lower dashed 6x page threshold again and
again. The solid orange 6h line stays near 4x, so the 6h & 30m pair never pages.*

## Timeline (UTC)

| Time | Event |
|------|-------|
| Oct 25 07:22 | Soak baseline starts: k6 `browse`, 20 users, about 10.6 checkouts/min, 0.1% payment failures |
| 08:00:34 | Trigger: the drill sets `PAYMENT_FAILURE_RATE=0.02` as an override on the Argo CD Application |
| 08:01:45 | First user impact: the first failed checkout from an updated pod |
| 08:02:34 | Rollout complete, every API pod at 2% |
| 09:20 | The 30m window crosses the 6x page threshold for the first time. The 6h window is far below 6x, so no page |
| 14:13:45 | Ticket condition true in Prometheus through the 3d & 6h pair: 3d at 1.002x, 6h at 4.3x |
| 14:18:00 | Condition false again: the 3d window dips under 1x. Alertmanager hadn't sent anything yet (5-minute group wait) |
| 14:21:15 | Condition true again |
| 14:26:10 | **Ticket** delivered to #alerts-ticket, "1.0x" |
| 14:43:52 | Mitigation: the drill removes the override, 30 min after the ticket first fired (17.5 min after Slack) |
| 14:44:52 | Rollout complete. Impact ended: no failed checkouts after 14:43:50 |
| 15:54:30 | Ticket resolves in Prometheus: the 3d window is below 1x |
| 15:56:10 | RESOLVED delivered to #alerts-ticket |

## Detection

**Ticket, not page: worked as designed, but the short windows did cross the page line.** No page condition was ever
true. That wasn't because the short windows stayed low: the 30m window was above 6x for 59 minutes in 10 separate
stretches (peak 8.4x), and the 5m window reached 20.4x. At about 10 checkouts a minute, a 30-minute window holds
about 300 checkouts, so 13 failures instead of the expected 6 put it over 6x. What kept those from paging was the
long half of each pair: the 6h window peaked at 4.4x (page at 6x), and the 1h window at 7.1x (page at 14.4x). A
single-window 30m alert would have paged about ten times. In Phase 1 the 30m window peaked at only 3.9x, but that
burn lasted 40 minutes at 17 checkouts a minute. Over 6.7 hours at 10 a minute, the noise had far more chances, and
this is the first run that shows the long window doing that job.

**Detection time: between the lab and production.** The ticket came through the 3d & 6h pair after 6h 12m. Phase 1
took 9 minutes, and the promtool scenario puts production at 15 to 16 hours (`prometheus/tests/slo_alerts_test.yml`).
It sits in between because the "3d" window held only 31 hours of traffic: 25 hours of healthy baseline, then the
burn. With 25 hours at 0.1%, a 2% burn needs about 6.6 hours to lift the whole window past 0.5%, which is what
happened. The 1d & 2h pair (3x) never fired: the 2h window was above 3x, but the 1d window peaked at 1.3x.

**One flap, absorbed by Alertmanager.** The 3d window was at 1.002x when the ticket fired, so it dipped under the
threshold 4 minutes later and came back 3 minutes after that. The ticket rule has no `for:` or `keep_firing_for`.
Alertmanager's 5-minute group wait swallowed the flap, so Slack got one message. But the wait restarted, and the
ticket reached Slack 12.5 minutes after the condition first held, instead of 5.

## Root cause and trigger

The trigger was an injected configuration change: the payment provider failed 2% of charges. As in Phase 1, checkout
has no retry or fallback provider, so every provider failure reaches the user. At 2%, that's about one failed
checkout every 5 minutes: a thin scatter on the failure-ratio graph. Only the budget math shows that it adds up.

## Resolution

The drill removed the override 30 minutes after the ticket first fired, standing in for someone working the ticket
that morning. Argo CD rolled the API back to the git value (0.1%) within a minute. The ticket stayed open another 71
minutes: it had fired through the 3d & 6h pair with the 3d window barely above 1x, so an hour of healthy traffic was
enough to pull it under. Had it fired through the 1d & 2h pair, it would have stayed open until the 2h window let go
of the burn, about 2 hours.

## What went well

- The severity matched the urgency: a ticket, and no page, despite 59 minutes of the 30m window above the page line.
- The drill ran unattended in the cluster. The fault and the fix each took effect within a minute, through the Argo
  CD Application, and a dashboard snapshot was taken at each step.
- The flap produced one Slack message, not three. Alertmanager recorded no failed Slack sends during the soak.

## What went poorly

- The flap delayed the ticket by about 7 minutes. That's harmless for a ticket, but it shows that a long window
  sitting on its threshold flaps.
- The lab still detects the slow burn 2.5 times faster than production would, because the cluster had 31 hours of
  history, not 3 days. The 6h 12m figure is not a production estimate.

## Where we got lucky

Nothing material. The 6h window's margin was comfortable: reaching 6x would have taken about 114 failures in a
6-hour window, against about 76 expected at 2%.

## Action items

| Action | Type | Owner | Tracking |
|--------|------|-------|----------|
| Add `keep_firing_for` (about 10 min) to the ticket rules, so a long window sitting on its threshold doesn't flap | detect | | |
| For production ticket timing, give a soak 3 days of baseline before the slow burn, or backfill the history (Phase 1 item) | process | | |
| Add a fallback payment provider or a retry policy (carried over from Phase 1) | prevent | | |
