# Postmortem: payment provider slow burn (experiment)

| | |
|---|---|
| Date | 2026-10-03 |
| Authors | Konrad Kelly |
| Status | draft |
| Severity | ticket |
| SLOs affected | checkout-availability (plus a cold-start checkout-latency page, see below) |
| Duration | 40 min of degraded checkout (19:50:50 to 20:30:21 UTC) |
| Time to detect | 9 min to the ticket in Prometheus, 13 min to Slack |
| Time to mitigate | n/a. The experiment kept burning for 30 min after the ticket on purpose, to show it never pages |

This was a planned experiment, roadmap Phase 1. It's the counterpart of the
[fast-burn experiment](2026-10-02-payment-outage-fast-burn.md): a failure rate too low to look like an outage, but high
enough to empty the error budget well before the 28-day window ends.

## Summary

From 19:50:50 the simulated payment provider failed 2% of charges. That's 4x the rate the 0.5% budget can sustain,
so left alone it would spend the whole 28-day budget in about a week. `StorefrontCheckoutAvailabilityBudgetBurn`
opened a **ticket** (not a page) after 9 minutes. The page never even went pending. The removed `> 5% for 5m`
threshold alert would never have fired.

Separately, a **checkout latency page** fired at 18:52, 2 minutes into the healthy baseline, because the JVM was
cold and Prometheus had only 2 minutes of data.

## Impact

- **Users:** 14 of 697 checkout attempts failed with 402 during the burn (2.0%).
- **Error budget:** at 16.9 checkouts/min the 28d budget is about 3,405 failed checkouts. The burn spent **0.41%**,
  and **0.18%** had been spent when the ticket fired.
- Projected: at 2% indefinitely, the full 28d budget would be gone in about 7 days. The old threshold alert would have
  stayed silent the whole time.
- Latency: 6 of 153 checkouts took over 500ms in the first 11 minutes after the stack started (max ~1.4s).
  At steady state it was 3 of 747.

## Timeline (UTC)

| Time | Event |
|------|-------|
| 18:49 | Compose stack started (cold JVM) |
| 18:50:26 | Prometheus storage cleared; k6 `browse` profile at 30 users, 0.1% payment failures |
| 18:52:29 | **Latency page** to #alerts-page, 7.1x (cold-start checkouts over 500ms, and only 2 minutes of data) |
| 19:02:00 | Latency page resolved; latency ticket opens (the longer windows still hold the cold start) |
| 19:50:50 | Trigger: API recreated with `PAYMENT_FAILURE_RATE=0.02` |
| 19:53:43 | Latency ticket resolved |
| 20:00:07 | **Availability ticket** condition true in Prometheus (3d/6h pair above 1x) |
| 20:00:15 | Latency ticket fires again (second cold start from the API recreate), resolved 20:04:54 |
| 20:03:58 | **Availability ticket** delivered to #alerts-ticket |
| 20:24:05 | Old-threshold ratio peaks at 4.8% (needs > 5% held for 5 min) |
| 20:30:21 | Experiment ends: failure rate back to 0.001. Page never pending or firing |

## Detection

**Ticket, not page: worked as designed.** At 4x, the burn sits between the ticket threshold (1x over 3d/6h,
3x over 1d/2h) and the page thresholds (6x, 14.4x). Every page window stayed below 6x. The 30m window peaked at
3.9x, so nobody would have been woken up for a problem that can wait until morning.

**The old threshold alert would have missed it entirely.** Its 5-minute ratio peaked at 4.8% and never held above 5%.
At only about 17 checkouts per minute, one failure moves a 5-minute ratio by over 1 point, so a fixed threshold near
the real failure rate is a coin flip: it either misses or flaps. The burn-rate ticket uses longer windows and doesn't
have that problem.

**The lab detected it far faster than production would.** The ticket came through the 3d/6h pair after 9 minutes,
because the "3d" window held only 70 minutes of data. With 3 real days of healthy history it takes **15–16 hours**,
also through the 3d/6h pair. A promtool scenario with this exact shape (3 days at 0.1%, then 2%) is quiet at 15h and
opens the ticket at 16h; it's now part of `prometheus/tests/slo_alerts_test.yml`. The 1d/2h pair (3x) never fired: the 2h window peaked at 1.8x, because the 60-minute
healthy baseline was still in it.

**Cold start paged on fresh data.** The latency page wasn't caused by the slow burn. The stack started a minute
before the experiment, so the first checkouts ran on a cold JVM (up to ~1.4s), and Prometheus had so little data that
"1h" meant "the last 2 minutes". With an hour of real history, 6 slow checkouts out of about 1,000 is 0.6%, 0.6x
burn, no page. But the cost of a cold start is real: about 4% of checkouts were slow for the first 10 minutes.

## Root cause and trigger

Trigger: a configuration change that made the payment provider fail 2% of charges. As in the fast-burn experiment,
checkout has no retry or fallback provider, so every provider failure reaches the user. The difference is
that 2% looks like noise on a dashboard, and it's the budget math that makes it visible.

## What went well

- The alert severity matched the urgency: ticket for a slow leak, no page.
- The experiment ran unattended for 1h40m with the keep-awake guard. The repo copy of the scripts worked
  on its first full run.
- The ticket included the burn rate (1.1x) and the runbook link.

## What went poorly

- A latency page during a healthy baseline. In a real on-call rotation, a page caused by a restart erodes trust in
  pages.
- Starting the stack right before the experiment mixed a cold start into the baseline. The baseline should begin
  after a warm-up.

## Where we got lucky

- The 5-minute ratio reached 4.8%. With slightly worse luck it could have crossed 5% for a few minutes. That's not
  enough for the old 5-minute hold, but it's a reminder that low-volume ratios are noisy.

## Action items

| Action | Type | Owner | Tracking |
|--------|------|-------|----------|
| Experiment scripts: send warm-up traffic and wait a few minutes before the baseline when the API was just (re)started | process | | |
| Warm the JVM before taking traffic (readiness gate after warm-up requests), so deploys don't burn latency budget | prevent | | Phase 2 (probes) |
| Backfill healthy history before live experiments, so detection times match production | process | | |
| Add the slow-burn shape (3d healthy, then 2%) as a promtool scenario to pin the production detection time (15–16h) | detect | | done in this change |
