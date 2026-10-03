# Postmortem: payment provider outage (fast burn experiment)

| | |
|---|---|
| Date | 2026-10-02 |
| Authors | Konrad Kelly |
| Status | draft |
| Severity | page |
| SLOs affected | checkout-availability |
| Duration | 14 min of user impact (22:58:50 to 23:13:03 UTC) |
| Time to detect | 3 min to the first alert (ticket), 9 min to the page |
| Time to mitigate | 5 min from page to recovery (scripted) |

This was a planned experiment, roadmap Phase 1. The "incident" was injected on purpose to see how the burn-rate
alerts behave against a real outage shape.

## Summary

At 22:58:50 the simulated payment provider started failing 30% of charges. `StorefrontCheckoutAvailabilityBudgetBurn`
paged #alerts-page 9 minutes later. Payment recovered at 23:13:03, but the page stayed up for another 26 minutes,
because the 6h/30m alert pair remembers an outage for about as long as the 30m window does.

## Impact

- **Users:** 50 of 213 checkout attempts failed with 402 over 14 minutes (23%).
- **Error budget:** the 28d budget at this traffic level (16.2 checkouts/min) is about 3,272 failed checkouts.
  The outage spent **1.54%** of it, and **1.07%** had been spent by the time the page fired.
- The dashboard's 1d budget read −700%. On a Prometheus that's only 75 minutes old, the "1d" window covers
  just those 75 minutes, so the number is meaningless. Use the 28d-equivalent figure above.

## Timeline (UTC)

| Time | Event |
|------|-------|
| 21:58:18 | Prometheus storage cleared; k6 `browse` profile at 30 users (baseline, 0.1% payment failures) |
| 22:58:39 | Trigger: API recreated with `PAYMENT_FAILURE_RATE=0.3` |
| 22:58:50 | First user impact (API healthy with the new setting) |
| 23:01:51 | Ticket condition true in Prometheus (3d/6h pair above 1x) |
| 23:05:35 | The removed threshold alert (`> 5% for 5m`) would have fired here |
| 23:06:42 | **Ticket** delivered to #alerts-ticket (after its 5-minute group wait) |
| 23:07:50 | **Page** delivered to #alerts-page, burn rate 6.2x, through the 6h/30m pair |
| 23:12:55 | Mitigation: API recreated with `PAYMENT_FAILURE_RATE=0.001` |
| 23:13:03 | Impact ends |
| 23:19 | 5m window back to 0. The 1h/5m pair no longer matters, but the 30m window is still at 22x |
| 23:39:12 | 30m window below 6x, page resolves in Prometheus |
| 23:41:56 | RESOLVED delivered to #alerts-page (after the 5-minute group interval) |
| 23:53 | Ticket still firing (2h/1d/3d windows still contain the outage), as intended |

## Detection

**Which alert fired, and why that one.** The 1h/5m pair (14.4x) never fired. The 1h window peaked at 11.2x after
14 minutes of a 23% failure rate. The page came from the 6h/30m pair (6x) instead, but only because the
"6h" window held just 70 minutes of data. With a real 6 hours of healthy history, the 6h pair would have needed
about 36 minutes and the 1h pair about 19 minutes (at 23% failures, the 1h window passes 14.4x after ~19 minutes). **The lab detected this faster than production would.**

**Compared with the old threshold alert.** The removed `> 5% for 5m` rule would have fired at 6.8 minutes, about
2 minutes before the page, and cleared about 4 minutes after recovery. On a large, sudden outage like this one,
a plain threshold is as fast or faster. The burn-rate design pays off on slow burns (experiment 2) and in not paging
on short blips, not in speed on big outages.

**Ticket before page.** The ticket reached Slack a minute before the page existed to mute it. On fresh data,
the 3d window isn't long, so the "slow" ticket condition held after 3 minutes. With real history, the 3d window
would dilute a 14-minute incident and the page would come first.

## Root cause and trigger

The trigger was a configuration change that made the payment provider fail 30% of charges, simulating a
provider outage. There was no defect in the storefront. Checkout availability depends directly on the provider,
and there's no fallback provider or retry, so provider failures pass straight through to users as 402s.

## Resolution

The failure rate was reset to 0.001 and the API recreated. Checkouts recovered immediately. Recreating the API
restarts the JVM, but the checkout latency SLO did not burn (no latency alert fired).

## What went well

- The page included the burn rate and a runbook link. The runbook's first step (compare the short and long windows)
  would have shown correctly that the outage was over after 23:19, while the page was still firing.
- No latency alert fired from the cold restarts.
- The page reached Slack within seconds of firing in Prometheus.

## What went poorly

- The page stayed up 26 minutes after recovery. Someone responding would see a firing page with a clean 5m window
  and wonder whether the fix had worked.
- Two notifications (ticket, then page) for one incident. That was caused by the short lab history, but it would
  confuse a responder.

## Where we got lucky

- The first run of this experiment was lost when the laptop went to sleep for 70 minutes. This run kept the
  machine awake. In production the equivalent is the monitoring stack itself going down. `StorefrontApiDown`
  covers the app, but nothing alerts when Prometheus or Alertmanager stop.

## Action items

| Action | Type | Owner | Tracking |
|--------|------|-------|----------|
| Runbook: say that a 6h/30m page can stay up to 30 min after mitigation, and to trust the 5m window | mitigate | | done in this change |
| Run lab experiments after 6+ hours of healthy traffic, or note that detection times are optimistic | process | | |
| Add a dead-man's-switch alert (always firing, routed to an external heartbeat) so a dead Prometheus/Alertmanager is noticed | detect | | Phase 2+ |
| Consider a fallback payment provider or retry policy, since provider failures pass straight to users | prevent | | |
