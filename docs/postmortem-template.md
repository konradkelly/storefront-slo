# Postmortem: <short title>

Copy to `docs/postmortems/YYYY-MM-DD-<slug>.md`.

**Blameless.** Describe what the system and process allowed to happen, not who made a mistake. "The deploy
pipeline didn't check the SLO", not "Alex deployed a bad build". People act on the information they had,
and the goal is to change what that information is.

| | |
|---|---|
| Date | YYYY-MM-DD |
| Authors | |
| Status | draft / reviewed / action items done |
| Severity | page / ticket |
| SLOs affected | e.g. checkout-availability |
| Duration | from first user impact to full recovery |
| Time to detect | first impact → first alert |
| Time to mitigate | first alert → impact stopped |

## Summary

Two or three sentences: what broke, who noticed it, how it was fixed.

## Impact

- **User impact:** what customers experienced, and how many. For example: "≈30% of checkouts failed for 22 minutes,
  about 270 failed orders."
- **Error budget spent:** `slo:<name>:error_budget_remaining` before and after. For example: "checkout
  availability went from 92% to 71% of budget remaining."
- Anything the SLIs missed, e.g. time the app was down and recorded nothing.

## Timeline (UTC)

| Time | Event |
|------|-------|
| hh:mm | Trigger (deploy, config change, dependency failure) |
| hh:mm | First user impact (from the SLI graph, not from the alert) |
| hh:mm | Alert fired: `<alertname>` severity=`<severity>`, burn rate `<value>`x |
| hh:mm | Responder acknowledged |
| hh:mm | Cause identified |
| hh:mm | Mitigation applied |
| hh:mm | Alert resolved / SLI back to normal |

## Detection

Did the right alert fire at the right severity, and early enough? How long from first impact to the alert,
and was that acceptable for the budget it cost? Would a different burn-rate window have caught it sooner,
or would that have added noise?

## Root cause and trigger

The **trigger** is what started it (a config change, a traffic spike). The **root cause** is why the system
couldn't absorb it. There's usually more than one contributing factor. A "5 whys" chain often helps.

## Resolution

What stopped the impact (rollback, config reset, scale-out), and what was done afterwards to fully recover.

## What went well

## What went poorly

## Where we got lucky

## Action items

| Action | Type | Owner | Tracking |
|--------|------|-------|----------|
| | prevent / detect / mitigate / process | | issue link |

Prefer actions that change the system (a test, an alert, a guardrail) over actions that ask people to be more careful.
