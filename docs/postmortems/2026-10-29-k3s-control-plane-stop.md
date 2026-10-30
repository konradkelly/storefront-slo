# Postmortem: k3s server stopped under load (Phase 4a experiment)

| | |
|---|---|
| Date | 2026-10-29 |
| Authors | Konrad Kelly |
| Status | draft |
| Severity | page (none was sent) |
| SLOs affected | catalog-availability, checkout-availability, cart-availability |
| Duration | 12m 9s of total outage (20:58:49 to 21:10:58 UTC) |
| Time to detect | Never paged. A catalog ticket was true in Prometheus after 2 minutes and reached the logger 20 seconds after the outage ended |
| Time to mitigate | Scripted: the instance was started after 10 minutes. Service was back 45 seconds after it was running |

This was the Phase 4a experiment ([ROADMAP](../ROADMAP.md), [docs/k3s.md](../k3s.md)): stop the single k3s server
while k6 runs, then compare with stopping an agent ([agent postmortem](2026-10-29-k3s-agent-stop.md)). It ran with
`scripts/experiments/k3s-node-stop.sh server` on a fresh cluster with 28 minutes of baseline load: k6 at 20 VUs
(`browse`, pinned to agent-1 so it would survive), plus two probers on a laptop, one through the server's Elastic
IP and one through an agent's own address.

## Summary

The prediction was that only traffic through the Elastic IP would stop, because ingress terminates on the server.
Instead everything stopped. The scheduler had put the Postgres primary, the only CoreDNS replica and Alertmanager
on the server too, so stopping it took the database, name resolution and alert delivery with the API server. No
page was sent: Alertmanager was gone, and the checkout SLO recorded no checkouts at all, failed or otherwise, so it
had nothing to burn. Starting the instance again fixed everything within 45 seconds, with no failover and no data
loss.

## Impact

- **Users:** every request failed for 12 minutes, through both entry points. Through the Elastic IP nothing
  answered. Through an agent, Envoy accepted the request and the API held it until the prober gave up at 5
  seconds. The probers logged 142 and 138 failures. At normal traffic this was about 13,600 catalog requests and
  780 checkouts that could not succeed.
- **Error budget, as users saw it:** a full outage of 12m 9s is **30%** of the 28-day catalog budget (99.9%: 40 min
  of full outage) and **6%** of the checkout budget (99.5%: 3h 22m).
- **Error budget, as the SLIs recorded it:** checkout **0%** (no checkout attempt completed, so none was counted),
  catalog **0.3%** (154 failed requests against a budget of about 45,000 at 1,124 requests/min). The SLIs saw about
  1% of the outage.
- Why so little was recorded: each API request waited 30 seconds for a database connection (HikariCP's default
  `connectionTimeout`) before failing with a 500. k6 is a closed loop, so its 20 VUs spent the outage waiting and
  sent 3% of their normal requests. Requests through the Elastic IP never reached the API at all.

![SLO dashboard, 6 hours to 22:09: checkout availability near 0x burn with 81% of its budget left, catalog
availability's 5m window at 1000x around 21:05](img/2026-10-29-k3s-node-stops-6h.png)

*Six hours to 22:09, including this outage (21:00 to 21:11) and the [agent stop](2026-10-29-k3s-agent-stop.md)
after it. Checkout availability (first row) stays near 0x and ends with 81% of its budget: neither outage registered.
Catalog availability (third row) shows the 5m window at 1000x for this outage, but the solid 1h line, the one a page
needs, barely moves.*

| Time | Event |
|------|-------|
| 20:30:40 | k6 starts: 20 VUs, `browse`, pinned to agent-1, about 1,000 requests and 10 checkouts per minute |
| 20:48:42 | Experiment starts. With the two probers, about 1,300 API requests and 64 checkouts per minute. The server runs the Postgres primary (`storefront-db-1`), CoreDNS (1 replica), Alertmanager, the CNPG operator, the Envoy Gateway controller, one of three API replicas, and the Elastic IP |
| 20:58:47 | **Trigger:** `aws ec2 stop-instances` on the server |
| 20:58:48 | The standby loses its WAL stream: the primary was shut down cleanly ("terminating connection due to administrator command"), because an EC2 stop is an orderly OS shutdown |
| 20:58:49 | First failed request: Envoy returns 503 while the server's pods terminate |
| 20:58:49 | The standby can no longer resolve `storefront-db-rw`: CoreDNS was on the server |
| 20:59:10 | Every request fails from here on: no connection through the Elastic IP, a timeout through the agent |
| 20:59:20 | Instance stopped |
| 20:59:58 | The standby's metrics go dark (`up=0`), although Postgres is fine: each scrape also collects Barman Cloud plugin metrics, which call the Kubernetes API, and the scrape times out |
| 21:00 | The checkout SLI records no checkouts of any status from here until 21:11. Its 5m ratio becomes NaN |
| 21:01:00 | `StorefrontCatalogAvailabilityBudgetBurn` severity=ticket true in Prometheus (5m 16x, 1h 1.8x). Not delivered: Alertmanager is down |
| 21:04 | Catalog 5m burn at 1000x (every recorded request fails). The 1h window, diluted by 48 minutes of good traffic, peaks at 5.4x, under the 14.4x page line |
| 21:07 | `AlertmanagerClusterDown` severity=critical true in Prometheus. Nowhere to send it |
| 21:09:54 | **Mitigation:** `aws ec2 start-instances` |
| 21:10:13 | Instance running |
| 21:10:39 | Server node Ready |
| 21:10:48 | First notifications: `TargetDown` warnings that were already out of date |
| 21:10:57 | The standby catches up from the WAL archive and resumes streaming |
| 21:10:58 | Last failed request. The primary is still `storefront-db-1`: no failover happened or was needed |
| 21:11:18 | Catalog ticket delivered ("5.4x"), 20 seconds after the outage ended |
| 21:35:00 | Catalog ticket resolves |

## Detection

Detection failed in three independent ways, and any one of them would have been enough to miss the outage.

1. **Alert delivery was on the failed node.** Alertmanager has one replica, and it ran on the server. Prometheus
   kept evaluating on agent-1, and alerts it fired had nowhere to go. `Watchdog`, the alert that exists to prove the
   pipeline works, goes to the `blackhole` receiver, so nothing outside the cluster noticed that it had stopped.
   [alertmanager.yml](../../alertmanager/alertmanager.yml) already says that a real setup would send it to an external
   dead man's switch.
2. **The checkout SLI recorded nothing.** It divides failed `POST /orders` requests by all of them, and during the
   outage there were none. Checkout is the last step of a session: a k6 session views 4-9 catalog pages first, and
   only 7.5% of sessions check out. With each of those requests taking 30-60 seconds to fail, k6's 20 virtual users
   got through about one request a minute each, and no session reached checkout in 12 minutes. The probers stop a
   session at its first failure. With zero attempts, the ratio is 0/0: no data, which can't burn budget. The
   fast-burn postmortem predicted this with a dead load generator ("alert when checkout traffic drops to zero").
   Here it happened with a dead database, and real customers who can't load a product page don't reach checkout
   either.
3. **The catalog SLI saw 1% of the outage.** It counted 154 of about 13,600 failed requests: the ones that got far
   enough to time out. With so few, the 1h window stayed at 5.4x and only a ticket fired. A full outage of a 99.9%
   SLO should page within a couple of minutes.

An outside-in check, a probe from somewhere other than this cluster that counts time rather than completed requests,
would have caught all of it. Phase 5 lists synthetic probing. This experiment argues for doing it before more SLO work.

## Root cause and trigger

**Trigger:** the server instance was stopped (deliberately). The same would follow from an instance failure, an AZ
problem in us-east-1a, or a k3s upgrade that reboots the server.

**Root cause:** the server is a single point of failure for much more than scheduling, and nothing stops ordinary
workloads from landing on it:

- k3s doesn't taint its server, so the scheduler treats it as one more node. CloudNativePG creates instance 1 first,
  and the first instance became the primary on the server.
- CoreDNS runs one replica, and it ran on the server. Every new connection by name fails without it.
- Alertmanager runs one replica, and it ran on the server.
- Failover needs the Kubernetes API: the CNPG operator promotes a standby by changing the Cluster and the
  `-rw` Service, and the standby can't promote itself. With the API server gone, a healthy standby on agent-0 sat
  unused for 12 minutes.
- The Elastic IP points at the server, so even a healthy data path on the agents could not receive user traffic.

Why didn't the agent path keep serving? Envoy on the agents was fine and accepted requests. The API pods on the
agents were fine. But they needed the database, and the database primary was on the server.

## Resolution

Starting the instance restored everything without intervention. The node was Ready 26 seconds after the instance was
running. Postgres came back as primary, with nothing to rewind, because the shutdown had been clean. The standby
fetched the missing segment from the S3 WAL archive and resumed streaming. All API replicas were Ready again within
a minute.

## What went well

- Recovery took 45 seconds after the instance was running, with no failover, no lost writes and no manual steps.
- Prometheus ran on an agent and kept recording, so the outage could be measured from inside the cluster too.
- The laptop probers measured time, not completed requests, and so recorded the outage the SLIs missed.

## What went poorly

- The outage was total, not the ingress-only outage predicted.
- No page was sent, and an SLO page could not have been sent.
- A healthy standby reported `up=0` for the whole outage, because its metrics endpoint depends on the API server
  through the backup plugin.

## Where we got lucky

**This was a clean stop.** EC2 stop shuts the OS down cleanly, and the root volume survives. A terminated or failed
server takes its disk with it, and on that disk are the k3s datastore (SQLite), which is the whole cluster's state,
and the Postgres primary's local-path volume. Recovering from that means a new cluster and a restore from S3. The
same evening's [restore drill](../k3s.md#restore-drill) took 58 seconds for a small database. WAL is archived
every 5 minutes at most (`archive_timeout`), so up to 5 minutes of orders could be lost.

## Action items

| Action | Type | Owner | Tracking |
|--------|------|-------|----------|
| Keep workloads off the k3s server: taint it (`CriticalAddonsOnly=true:NoExecute`) and give system pods that must stay a toleration, or run three servers with embedded etcd. Phase 4b removes the issue | prevent | | |
| CoreDNS: two replicas, spread across nodes | prevent | | |
| Alertmanager: two replicas spread across zones, and route `Watchdog` to an external dead man's switch (Grafana Cloud or healthchecks.io) | detect | | |
| Outside-in synthetic probe as an SLI, run from outside the cluster (Phase 5, moved earlier) | detect | | |
| Alert when checkout attempts drop to zero or far below the previous hour (carried over from the fast-burn postmortem, now seen for real) | detect | | |
| Shorten HikariCP `connectionTimeout` (30s default) to a few seconds, so a database outage fails fast and gets counted | detect | | |
| Barman Cloud plugin: two replicas with a PDB. While it is down, CNPG doesn't fail over at all ([tested](2026-10-29-k3s-agent-stop.md#the-backup-plugin-blocks-failover-tested-afterwards)) | prevent | | |
