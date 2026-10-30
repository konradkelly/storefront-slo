# Postmortem: k3s agent stopped under load, and the server it overloaded (Phase 4a experiment)

| | |
|---|---|
| Date | 2026-10-29 |
| Authors | Konrad Kelly |
| Status | draft |
| Severity | page (none was sent) |
| SLOs affected | catalog-availability, checkout-availability, checkout-latency |
| Duration | 47 seconds when the agent stopped (21:31:56 to 21:32:43 UTC), then 13m 20s degraded to down when its pods landed on the server (21:42:10 to 21:55:30) |
| Time to detect | No page. A checkout latency ticket was true after 5 minutes of the second phase and was delivered 12 minutes in |
| Time to mitigate | 8m 47s from the first failure of the second phase to a manual reboot of the server, and 13m 20s to the last failure |

The second half of the Phase 4a experiment, run 25 minutes after the
[control-plane stop](2026-10-29-k3s-control-plane-stop.md) on the same cluster and load:
`scripts/experiments/k3s-node-stop.sh agent-0` with `STOP_MIN=7`, long enough to pass the 5-minute point at which
Kubernetes evicts pods from an unreachable node.

## Summary

Stopping agent-0 cost 47 seconds of failed requests, until the node was marked NotReady and its endpoints were
removed, as predicted. Five minutes later, Kubernetes evicted agent-0's pods. The zone spread let the API replica
reschedule into us-east-1a, so it landed on the server, together with Grafana and an Envoy proxy. The server
already ran the control plane, the Postgres primary, CoreDNS and Alertmanager. Its memory went from 72% to 97% in
three minutes, it began to thrash, and the API server stopped answering. Checkouts fell by about 75% for ten minutes.
Because the API server didn't answer, agent-0 couldn't rejoin when it was started again. A manual reboot of the
server and moving the three pods back to agent-0 ended it. A separate test afterwards showed that while the backup
plugin's only pod is gone, the database operator will not fail over at all.

## Impact

- **Node loss (47 s):** 19 failed prober requests across both entry points, all at the connection level. The API's
  own counters recorded none of them.
- **Cascade (13m 20s):** 102 and 106 failed prober requests. From 21:43 to 21:54 about 195 checkouts went through
  instead of about 780 (k6 plus the probers). The checkout SLI recorded **no failed checkout**, only fewer attempts,
  as in the control-plane stop. The catalog SLI recorded 25 server errors.
- **Error budget, as users saw it:** roughly ten minutes at a quarter of normal throughput and two minutes fully
  down. That is on the order of 20-25% of the 28-day catalog budget and 5% of the checkout budget. The SLIs
  recorded almost nothing.
- **Control plane:** unreachable from 21:41 to 21:52. No scheduling, no rollouts, no `kubectl`. SSM commands to the
  server stayed Pending.

![SLO dashboard, 6 hours to 22:09, covering both node stops: checkout availability near 0x burn with 81% of its
budget left, checkout latency spiking to about 60x at 21:50](img/2026-10-29-k3s-node-stops-6h.png)

*Six hours to 22:09, both experiments included. The cascade shows up only in checkout latency (second row, the 5m
window near 60x around 21:50). Checkout availability (first row) stays near 0x with 81% of its budget left. The
small cart spike just before 22:10 is the plugin test below.*

## Timeline (UTC)

| Time | Event |
|------|-------|
| 21:26:34 | Experiment starts. Agent-0 (us-east-1b) runs the Postgres standby, one API replica, one of two Envoy proxies, Grafana, the only Barman Cloud plugin pod, the KEDA metrics API server, the Prometheus operator and Argo CD's server |
| 21:31:52 | **Trigger:** `aws ec2 stop-instances` on agent-0 |
| 21:31:56 | First failed request: Envoy 503 for a request routed to agent-0's API pod |
| 21:32:43 | Last failure of this phase: the node is NotReady, its endpoints are removed, API at 2/3 |
| 21:32:45 | CNPG operator: "Cluster cannot proceed to reconciliation due to an error while interacting with plugins". The Barman Cloud plugin was on agent-0 |
| 21:33:42 | Instance stopped (110 seconds, against 33 for the server) |
| 21:37:55 | Taint-based eviction. The API replica, Grafana and the Envoy proxy are rescheduled onto the **server**. The standby can't move: its local-path volume is on agent-0 |
| 21:38:30 | The plugin runs again elsewhere. CNPG reconciles again: it was blocked for about 6 minutes |
| 21:39 | Server memory 87% (72% before the eviction) |
| 21:41 | Server memory 97%. `kubectl` times out: the API server no longer answers |
| 21:41:56 | Agent-0 running again, but it can't rejoin: the API server doesn't answer |
| 21:42:10 | First user-facing failure of the cascade. From 21:43, checkouts at 5-20/min instead of about 65 |
| 21:43 to 21:50 | The server stops reporting its own metrics. An SSM command to it stays Pending. EC2 status checks say ok |
| 21:47:00 | `StorefrontCheckoutLatencyBudgetBurn` severity=ticket true in Prometheus |
| 21:47:35 | Alertmanager sends **RESOLVED** for the catalog ticket, which was still firing in Prometheus. Alertmanager ran on the thrashing server, stopped getting updates, and timed the alert out |
| 21:50:57 | **Mitigation:** `aws ec2 reboot-instances` on the server |
| 21:51 to 21:53 | Total outage while the server reboots |
| 21:52:37 | API server answers (100 s after the reboot). Server cordoned |
| 21:52:57 | Agent-0 Ready, empty |
| 21:53 to 21:55 | The three pods restart on the server, their assigned node: memory back to 87% |
| 21:54:16 | KEDA scales the API from 3 to 6 on CPU (every JVM on the server starting at once) |
| 21:54:18 | Checkout latency ticket delivered, 7 minutes after it fired |
| 21:55:12 | CNPG switches the primary to `storefront-db-2` on agent-0: its default for a primary on a cordoned node |
| 21:55:15 | The three pods deleted with the server cordoned; they reschedule onto agent-0. Server memory 68% |
| 21:55:30 | Last failed request |
| 21:56:00 | Server uncordoned |

## Detection

Neither phase paged. The first phase was too short to need one. The second should have paged, and again the
checkout SLI recorded fewer attempts rather than failures. The only signal was a latency ticket, which reached the
logger 7 minutes after it fired because the Alertmanager delivering it was on the thrashing node. That same
Alertmanager sent a false RESOLVED for the catalog ticket during the incident.

The memory pressure fired nothing either. `NodeMemoryLow` (k8s/monitoring/node-alerts.yaml) needs under 10%
available for 15 minutes. The server crossed 90% used at 21:40, and its node-exporter stopped reporting at 21:43, a
gap that resets the timer. A ticket after 15 minutes would have been late for a node that runs the control plane.

## Root cause and trigger

**Trigger:** an agent node stopped (deliberately). The same would follow from any agent failure that lasts more than
5 minutes, the default `tolerationSeconds` for `node.kubernetes.io/unreachable`.

**Root causes:**

1. **Evicted pods moved onto the control-plane node.** The API's zone spread uses `nodeTaintsPolicy: Honor`, added
   after exp4 so that draining a zone's only node wouldn't leave its replacement Pending. A failed node is tainted
   too, so its zone was left out and us-east-1a, the server's zone, was allowed. k3s doesn't taint its server, so
   nothing else kept the pod off it.
2. **The scheduler counts requests, not usage.** The API requests 384Mi and may use 768Mi, and Grafana and Envoy
   use more than they request. The three pods fit the server's free requests, but not its free memory.
3. **The server stalled instead of shedding load.** For ten minutes memory stayed at 96-98%, the API server, the
   node's own metrics and the SSM agent stopped answering, and EC2 status checks still passed at 43% CPU. That
   looks like thrashing: with no swap, the kernel keeps dropping program pages and reading them back, and the OOM
   killer only acts once it can't. The kernel log was lost in the reboot, so this is inferred, not seen. k3s
   reserves no memory for itself by default (`--kube-reserved`, `--system-reserved`), so kubelet eviction had no
   margin to act in either.
4. **No rebalancing.** Pods stay on the node they were assigned to. Rebooting the server freed memory for a minute,
   then the same pods started there again. The fix needed a cordon and a delete.

## The backup plugin blocks failover (tested afterwards)

At 21:32:45 the operator stopped reconciling the database cluster because its only Barman Cloud plugin pod was on
agent-0. Failover happens inside that same reconcile loop. To check whether a plugin outage really blocks it, with
both instances healthy (primary `storefront-db-2`):

| Time | Event |
|------|-------|
| 22:03:38 | Plugin scaled to 0 replicas. Cluster status: "cannot proceed to reconciliation" |
| 22:04:00 | Primary pod `storefront-db-2` deleted |
| 22:04 to 22:07 | **No failover.** The standby isn't promoted, the deleted pod isn't recreated, and the Cluster status still says 2/2 ready with `storefront-db-2` as primary. Zero checkouts, and zero failed checkouts recorded |
| 22:07:34 | Plugin scaled back to 1 |
| 22:07:53 | Failover from `storefront-db-2` to `storefront-db-1`, 19 s after the plugin was back |
| 22:08:21 | Cluster healthy, both instances |

A 3m 57s database outage from a pod deletion that CNPG normally handles in under a minute (43 s in the 2.1
failover experiment on kind). The backup plugin is a hidden single point of failure for the database's availability.

## Resolution

A reboot of the server (100 s until the API server answered), then cordoning the server and deleting the three
pods so they rescheduled onto the now-empty agent-0. The cordon made CNPG move the primary to agent-0 (a
switchover, a few failed requests). The server was uncordoned once everything ran elsewhere.

## What went well

- The node loss itself was handled as designed: endpoints removed in about 45 seconds, PDB and spread kept two
  API replicas serving, and no database impact because only the standby was lost.
- The standby on a local-path volume waited for its node and rejoined without a rebuild.
- The reboot brought the API server back in 100 seconds.

## What went poorly

- A routine agent failure turned into a control-plane outage and a 13-minute customer-facing incident.
- Rebooting wasn't enough. Recovery needed someone who knew which pods had moved.
- The database operator was blocked for 6 minutes by a backup component.
- A false RESOLVED was sent during the incident.
- `k3s-node-stop.sh` waited for the agent to be Ready and so logged nothing useful during the cascade. The laptop
  probers and Prometheus (on agent-1) carried the measurement.

## Where we got lucky

- The Postgres primary was on the server. Had it been on agent-0 when the plugin pod went with it, the primary would
  have been lost with no failover for at least 6 minutes, until eviction rescheduled the plugin.
- The stalled server held the primary, and nothing killed it. A killed Postgres on a node whose API server
  doesn't answer would not have been restarted by anyone.

## Action items

| Action | Type | Owner | Tracking |
|--------|------|-------|----------|
| Keep workloads off the k3s server (taint, see the control-plane postmortem). This alone would have prevented the cascade | prevent | | |
| Reserve memory on every node for k3s and the OS (`--kube-reserved`, `--system-reserved`, and an earlier `--eviction-hard`) so kubelet evicts pods before the node thrashes | prevent | | |
| Set memory requests to measured usage for the API (JVM) and Grafana, so the scheduler can't overcommit a node | prevent | | |
| Barman Cloud plugin: 2 replicas spread across nodes, with a PDB | prevent | | |
| Alert when a CNPG Cluster is not in a healthy phase for more than 2 minutes | detect | | |
| Alertmanager: 2 replicas spread across zones (control-plane postmortem), which also prevents the false RESOLVED | detect | | |
| Rebalance after a node returns: run the descheduler, or add a runbook step to delete pods that moved during an outage | mitigate | | |
| Phase 4b: compare with EKS, where the control plane isn't a node the scheduler can fill | process | | |
