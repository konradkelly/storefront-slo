# SLO experiments

Scripts for the Phase 1 experiments in [docs/ROADMAP.md](../../docs/ROADMAP.md). Each one breaks checkout on purpose
and records a minute-by-minute timeline of burn rates, budget and alert states. That timeline is the raw
material for a postmortem ([template](../../docs/postmortem-template.md)).

| Script | What it does | Expected result | Time |
|--------|--------------|-----------------|------|
| `exp1-fast-burn.sh` | 30% payment failures until the page fires, +5 min, then recovers and watches 40 min | Page in about 9 min, clears about 26 min after recovery. Done, see [postmortem](../../docs/postmortems/2026-10-02-payment-outage-fast-burn.md) | ~1h55m |
| `exp2-slow-burn.sh` | 2% payment failures (4x burn) until the ticket fires, +30 min | Ticket after ~16 min, **no page**, old `> 5% for 5m` threshold never crosses | ~1h50m |

## Before you run one

- **It clears Prometheus storage** (`docker compose rm -sfv prometheus`) so old data doesn't skew the numbers, and
  recreates the API with a different `PAYMENT_FAILURE_RATE`. Real Slack notifications go out.
- The Compose stack must be up (`docker compose up -d`). Run the scripts from **Git Bash**. They need `docker`,
  `curl` and Python (set `PYTHON=python3` if that's its name).
- **Keep the machine awake.** The first run of experiment 1 was lost to a 70-minute sleep. On Windows, in a second
  terminal: `powershell -File scripts/experiments/keep-awake.ps1 -Minutes 120`. Keep the lid open and plugged in.

## Running

```bash
bash scripts/experiments/exp2-slow-burn.sh | tee exp2.log
```

`BASELINE_MIN` sets the healthy warm-up (default 60). Burn-rate alerts assume the long windows are actually long.
After a storage reset, the "6h", "1d" and "3d" windows hold only what has happened since, so alerts fire earlier
than they would in production. A longer baseline makes the lab more realistic. Six hours or more makes the 6h
pair behave as designed.

Output lines look like:

```
07:12:31 [burn] burn 5m=4.1 30m=3.9 1h=3.2 6h=1.1 2h=1.1 1d=1.1 3d=1.1 | budget1d=72.4% | checkouts/min=15 failed/min=0 | alerts CheckoutAvailability/ticket:firing | old-threshold-ratio5m=2.0%
```

`snap.py` prints one of these on its own: `python scripts/experiments/snap.py now`.

## Measuring budget spent

On fresh data, the dashboard's 1d budget is computed over however much data exists, so it reads very
negative and means little. For a postmortem, compare failed checkouts with the 28-day budget at the observed traffic
level instead: `0.005 × checkouts per minute × 40,320`. Query the failed count from Prometheus before the next
experiment clears storage.
