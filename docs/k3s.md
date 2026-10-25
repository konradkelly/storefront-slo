# k3s on EC2 (Phase 4a)

The storefront on a cloud cluster you run yourself: one k3s server and two agents on EC2, one per zone in
us-east-1, with the same platform, SLO rules, dashboards and Argo CD delivery as kind.

```
terraform/aws/bootstrap   once: state bucket, budget alert, GitHub OIDC role   (~$0/month, kept)
terraform/aws/k3s         make up / make down: VPC, nodes, IAM, backup bucket   (~$0.15/hr while up)
k8s/overlays/k3s          what Argo CD deploys: base + S3 backups + GHCR image
scripts/k3s-up.sh         terraform apply → kubeconfig → platform → Argo CD
```

## First time

1. **Bootstrap** (once per account):
   ```bash
   cd terraform/aws/bootstrap
   cp terraform.tfvars.example terraform.tfvars   # set budget_email
   terraform init && terraform apply
   gh variable set AWS_K3S_ROLE_ARN --body "$(terraform output -raw github_role_arn)"
   ```
   The budget covers the **whole account**, not only this project.
2. **A published image.** Argo CD deploys the digest that Release writes into `k8s/overlays/k3s`. Until the first
   release (blocked by the vulnerability gate, see [delivery.md](delivery.md)), `make up` builds everything except
   the storefront app itself, and argocd-up.sh says so.
3. **Push** `k8s/overlays/k3s` to main: Argo CD reads GitHub, not your working tree.

## Daily use

```bash
make up      # ~10 min from nothing; rerun any time (also after your IP changes)
make down    # back to $0/day
```

`make up` prints the URLs. The API (6443) and HTTP (80) are open to your current IP only, SSH is closed, and a node
shell is `aws ssm start-session --target <instance-id>`. kubectl uses its own kubeconfig, which is never merged
into your main one:

```bash
export KUBECONFIG=~/.kube/storefront-k3s.yaml
kubectl --context k3s-storefront get nodes -L topology.kubernetes.io/zone
```

The nightly workflow (`.github/workflows/k3s-nightly-destroy.yml`, 07:00 UTC) destroys whatever is still up.

## Cost (us-east-1, on-demand)

| Item | Rate |
|------|------|
| 3 × t3.medium | $0.125/hr |
| 3 public IPv4 addresses (incl. the server's Elastic IP) | $0.015/hr |
| 3 × 30 GB gp3 | ~$0.010/hr |
| S3 backups, SSM parameters, data transfer | cents |
| **Total** | **~$0.15/hr, ~$3.60/day if left up** |

No load balancer (ServiceLB uses the nodes' own ports) and no NAT gateway. A NAT gateway gives instances in
*private* subnets a way out. These nodes sit in public subnets with their own addresses, so they reach the
internet directly. A NAT gateway ($0.045/hr + $0.045/GB) would cost more than all three nodes. The trade-off: the
security group is the only thing keeping inbound traffic out, where private subnets would add a second layer.
Phase 4b moves the nodes into private subnets.

## Keeping the data

In-cluster Prometheus stores to an `emptyDir`, so `make down` deletes every metric. With
`k8s/monitoring/secrets/grafana-cloud.env` present (setup: [k8s/monitoring/secrets/README.md](../k8s/monitoring/secrets/README.md)),
`make up` also copies a curated subset to Grafana Cloud's free tier: the SLO results, request and payment
latency, checkouts, pool usage, restarts, node memory/disk/CPU, and Postgres archiving
([kps-remote-write.yaml](../k8s/monitoring/kps-remote-write.yaml)). Those series outlive the cluster (14 days on
the free tier), are labeled `cluster="k3s-aws"`, and the committed dashboards import directly. Screenshot or
link them in write-ups before they age out.

## How long to run it

Size runs by the alert windows, not the calendar:

| Alert | Windows | Needs |
|-------|---------|-------|
| Page (fast burn) | 1h/5m, 6h/30m | 1-6 hours of data |
| Ticket (slow burn) | 1d/2h, 3d/6h | 1-3 days |
| Error budget | 28d | ~$100 of uptime; not worth it in 4a, and the 28-day figures stay partial |

| Run | Duration | Cost |
|-----|----------|------|
| Shakedown: `make up` works, fill in the list below | 2-3 h | ~$0.50 |
| Experiment sessions: control plane stop, agent stop, NetworkPolicy re-test, backup restore drill | 2-4 h each | ~$0.50 each |
| Soak: steady low load, to see ticket alerts, daily backups, memory/disk trends on real data | 72 h (24 h if tight) | ~$11 ($3.60) |

About $15 for the whole phase. Give each session ~30 minutes of baseline load before breaking anything, so the
short windows have something to compare against.

**Soak run:**

```bash
make up && make keep HOURS=76          # the nightly destroy skips until then (capped at 7 days)
export KUBECONFIG=~/.kube/storefront-k3s.yaml
kubectl --context k3s-storefront -n storefront create configmap k6-script --from-file=loadtest/checkout.js
sed 's/name: k6-load/name: k6-soak/' k8s/loadtest/k6-job.yaml |
  kubectl set env --local -f - DURATION=72h VUS=20 -o yaml | kubectl --context k3s-storefront apply -f -
# ...72 hours later
make down && make unkeep
```

20 VUs of the `browse` profile is about 5 checkouts a minute. At 2 VUs (0.5 a minute) a couple of unlucky failures
in a 30-minute window can page during a 2% slow burn, so the alerts would be testing noise instead of the design.

**SLO drill on the soak** (`scripts/experiments/k3s-soak-drill.sh`): after a day of baseline, a 2% slow burn that
should open a ticket and never page, reverted 30 minutes after the ticket; a day later, a 30% fast burn that should
page, reverted 5 minutes after the page. Faults go in through git (`k3s-fault.sh` commits
`k8s/overlays/k3s/payment-fault.yaml` with `[skip ci]`), because Argo CD reverts `kubectl set env` within minutes.
The drill runs on your machine, logs a timeline like the Phase 1 experiments, and resumes from `soak-drill.state`
if restarted:

```bash
powershell -File scripts/experiments/keep-awake.ps1 -Minutes 4500   # in its own terminal
SLOW_AT=2026-10-26T08:00:00Z PAGE_AT=2026-10-27T16:00:00Z END_AT=2026-10-28T07:25:00Z \
  bash scripts/experiments/k3s-soak-drill.sh >> soak-drill.log 2>&1
```

With a one-day baseline, expect the ticket after about 6.5 hours of slow burn, through the 3d & 6h pair: the "3d"
window holds only what exists, about 30 hours. With three full days of history it would take about 15 hours.

**Pictures:** a CronJob (`k8s/monitoring/grafana-snapshots.yaml`) renders both dashboards every hour through
Grafana's image renderer and copies them to the backup bucket. `make down` downloads them to `grafana-snapshots/`,
and the nightly destroy saves them as a workflow artifact first. For an extra set at any moment:
`kubectl -n monitoring create job --from=cronjob/grafana-snapshots snap-<event>`.

## What I had to run myself

Phase 4b is structured around this list: each row is something EKS, or another AWS service, takes over.

| Piece | How it works on k3s | What breaks, or what it costs you |
|-------|---------------------|-----------------------------------|
| **Control plane** | One k3s server (API server, scheduler, controllers, SQLite datastore) on an ordinary EC2 instance, which also runs workloads | Lose that instance and nothing can be scheduled, scaled or rolled out (see the experiment). No HA without 3 servers and embedded etcd. Upgrades are yours. |
| **Node provisioning** | Terraform `aws_instance` + user_data that installs a pinned k3s | Changing the k3s version replaces every node at once. No autoscaling, and a dead node stays dead. |
| **Node identity in the cluster** | Zone/region labels passed by user_data. Without them the API pods never schedule, because their zone spread uses `DoNotSchedule` | A cloud provider integration would set these. Here a wrong label is silent. |
| **Pod identity for AWS** | None. IMDSv2 with hop limit 1 hides the node role from pods, so the backup sidecar uses a static IAM access key in a Secret | The key never expires and lives in Terraform state and in the cluster. EKS Pod Identity replaces it with a role (`inheritFromIAMRole`). |
| **Cluster secrets** | Join token and admin kubeconfig in SSM Parameter Store, `--secrets-encryption` for etcd/SQLite | Rotation is manual. |
| **Load balancing** | ServiceLB claims port 80 on every node; the Elastic IP points at the server | All traffic enters through the server's IP. If the server stops, so does ingress, even though agents still run Envoy. |
| **Storage** | local-path: each PVC is a directory on one node's root disk | A Postgres volume dies with its node. WAL archiving and daily base backups to S3 cover data, not availability. |
| **Database backups** | CloudNativePG Barman Cloud plugin + cert-manager → S3, bucket destroyed by `make down` | Backups don't outlive the environment. |
| **NetworkPolicy** | k3s's embedded kube-router enforces it (unlike kind's default CNI) | Re-test with `scripts/netpol-check.sh` (done when: same results as on kind). |
| **Node health** | `k8s/monitoring/node-alerts.yaml` (disk, memory) → ticket | You patch the OS and replace nodes yourself. |

Add a row whenever 4a makes you do something by hand.

## Experiment: stop the control plane

While k6 runs (`k8s/loadtest/k6-job.yaml`), stop the server: `aws ec2 stop-instances --instance-ids <server>`.
Expect traffic through the Elastic IP to stop with it (it terminates on the server). Agents keep their pods
running, but nothing can be scheduled, scaled or rolled out until the server is back. Measure the error budget
spent, then repeat by stopping an agent instead. Write it up with docs/postmortem-template.md.
