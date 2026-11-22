# EKS (Phase 4b)

The same storefront on Amazon EKS, replacing the pieces k3s made us run ourselves ([k3s.md](k3s.md), "What I had to
run myself"). It's being built in slices, each working before the next
([ROADMAP](ROADMAP.md#phase-4b-migrate-to-eks-later-sprint)):

1. **The cluster**: network, control plane, nodes, EKS add-ons, nightly destroy. *Done, checked on 2026-11-21 (below).*
2. **The platform**: Argo CD and `k8s/platform` on EKS, Envoy Gateway behind a Network Load Balancer, Postgres on
   EBS, backups through Pod Identity instead of a static key. *Running, checked on 2026-11-21 (below); destroying it
   with a load balancer is still to check.*
3. The database: the EKS database as a replica of the k3s archive in S3, and a cutover rehearsal.
4. External Secrets, for the Secrets `make up` still creates from local files.
5. The cutover: a domain, weighted DNS (10% → 50% → 100%), then the zone-failure experiment.

```
terraform/aws/bootstrap   once: state and backup buckets, budget, the CI role (now also allowed to destroy EKS)
terraform/aws/eks         make eks-up / make eks-down: VPC, EKS control plane, node group, add-ons, the NLB's
                          Elastic IPs, Pod Identity roles
k8s/platform              values-eks.yaml: the same app-of-apps, plus the AWS Load Balancer Controller
k8s/cluster/eks           the Gateway behind an NLB (k8s/gateway/gateway-eks.yaml), the gp3 StorageClass
k8s/overlays/eks          the k3s overlay, with backups through Pod Identity to eks/ in the bucket
```

## Using it

Apply the bootstrap change once first. The nightly destroy's role needs it to destroy EKS, and without it a
forgotten cluster keeps running:

```bash
terraform -chdir=terraform/aws/bootstrap apply
make eks-up      # the cluster (15-20 minutes), then Argo CD installs the platform (10-30 more)
make eks-down    # about 15 minutes
make eks-plan    # what would change, without changing it
bash scripts/netpol-check.sh eks   # the NetworkPolicies, enforced by the VPC CNI, and the Gateway through the NLB
```

`make eks-up` prints the addresses: the storefront on `http://<NLB IP>/products`, and Grafana, Prometheus and
Alertmanager on `<name>.<NLB IP>.sslip.io`. As on k3s, they answer only the IP you ran it from.

kubectl calls `aws eks get-token` for every request, so the AWS CLI must be logged in as the identity that ran
`make eks-up`: EKS made that identity the cluster admin. The API's public endpoint admits only the IP you ran it
from; rerun `make eks-up` after your IP changes.

The nightly destroy ([k3s-nightly-destroy.yml](../.github/workflows/k3s-nightly-destroy.yml)) destroys EKS as well
as k3s, and `make keep HOURS=…` keeps both.

## Cost (us-east-1, on-demand)

| Piece | Price |
|-------|-------|
| EKS control plane, standard support | $0.100/hr |
| 3 × t3.medium nodes | $0.125/hr |
| NAT gateway | $0.045/hr, plus $0.045 per GB through it |
| The NAT gateway's public IPv4 | $0.005/hr |
| 3 × 30 GB gp3 root volumes | about $0.010/hr |
| Network Load Balancer | $0.0225/hr, plus about $0.006 per unit of use (a lab barely uses one) |
| The NLB's 3 Elastic IPs | $0.015/hr |
| Postgres's 2 × 1 GiB gp3 volumes | under $0.001/hr |
| **Total** | **about $0.33/hr, $8/day** |

That's about $0.14/hr more than k3s ($0.19/hr). The control plane costs about what the k3s server did. Most of the
difference is the NAT gateway and the load balancer, the two things that replace the server's public IP.

## Choices

| Choice | Why | What it costs |
|--------|-----|---------------|
| **Its own VPC** (10.50.0.0/16) and Terraform stack | The cutover runs both clusters at once, and `make down` destroys the k3s VPC. The clusters share only the backup bucket. | Nothing; a different CIDR keeps peering possible. |
| **Private subnets, one NAT gateway** | Nodes and pods have no public IPs. | If the NAT's zone fails, every node loses outbound traffic. Three NAT gateways would cost $0.09/hr more. |
| **S3 gateway endpoint** | Backups and the layers of EKS's own images (ECR serves them from S3) skip the NAT, and its per-GB charge. | Free. |
| **Kubernetes 1.35** | 1.34 (kind, k3s) leaves standard support on 2026-12-01, and extended support is $0.60/hr. 1.35 is supported until 2027-03-26, and one minor ahead is within the version skew policy. | kind and k3s are one minor behind until all three are upgraded. |
| **`upgrade_policy: STANDARD`** | At the end of standard support EKS upgrades the cluster instead of charging for extended support. | An upgrade you didn't choose, if one is ever left that long. |
| **Managed node group**, 3 × t3.medium, one per zone | AWS replaces and upgrades the nodes. | No autoscaling beyond 3 nodes. Karpenter is a later step. |
| **Prefix delegation, 40 pods per node** | Without it the VPC CNI fits 17 pods on a t3.medium; this stack needs about 22 per node. 40 leaves room without letting one node take more pods than its memory holds. | Nothing measurable: each node reserves 542 MiB either way, sized for 17 pods, and has 3,293 MiB allocatable. |
| **IMDSv2 with hop limit 1** | Pods can't reach the node's IAM role, as on k3s. | Controllers that read instance metadata need their region and VPC passed in: the load balancer controller gets them in its values. |
| **EKS Pod Identity** for workloads | Short-lived credentials per service account: the EBS CSI driver, the load balancer controller, and the Postgres pods' backup sidecar, instead of k3s's static key. | A NetworkPolicy that lets the Postgres pods reach the agent on each node (169.254.170.23:80). |
| **NetworkPolicy by the VPC CNI** | k3s enforced it with kube-router, kind with Calico. | Nothing: `scripts/netpol-check.sh eks` gives the same results as on k3s. |
| **Access entries** (EKS API), not the aws-auth ConfigMap | Who can use the cluster lives in EKS and Terraform. | Only the identity that ran `make eks-up` is admin. |
| **No control-plane logs** | CloudWatch ingestion costs $0.50 per GB, and audit logs are large. | Turn on `api` and `audit` when debugging. |

## The platform (slice 2)

Argo CD installs the same app-of-apps as on kind and k3s (`k8s/platform`, `values-eks.yaml`), and EKS changes three
things.

**How traffic gets in.** A Network Load Balancer, made by the AWS Load Balancer Controller, sits in front of the same
Envoy Gateway. The NLB only gets packets into the VPC and across zones; Envoy still does the routing: the
HTTPRoutes, the hidden `/actuator`, and the canary's traffic split. Compared with k3s, where every request entered
through the server's Elastic IP, losing a node or a zone now only removes its targets.

| Setting | Why |
|---------|-----|
| Targets are the Envoy pods' IPs (`nlb-target-type: ip`) | The VPC CNI gives pods VPC addresses, so the NLB sends straight to them, not through a port on every node. |
| Cross-zone load balancing on | Two Envoy pods across three zones leave one zone without one, and the monitoring hostnames use one of the NLB's addresses. Every address must reach every pod. |
| Three Elastic IPs from Terraform | The controller makes the NLB halfway through Argo CD's sync, but the monitoring UIs need their `<name>.<ip>.sslip.io` hostnames up front. These cost the same as the NLB's own public IPs. |
| `loadBalancerSourceRanges`: your IP only | As on k3s, where the security group admitted only `admin_cidrs`. The controller turns it into the NLB's security group rules. |
| The controller's own Gateway API support off | Envoy Gateway owns the Gateway resources here. |
| The controller's Service webhook off | Its `failurePolicy` is `Fail`, so while the controller was down no Service could be created anywhere in the cluster. The Gateway's Service names its load balancer class itself. |
| Envoy pods spread across zones, preferably | Losing a zone leaves one Envoy. Preferred, not required, so a replacement still starts while a zone is down. |

**Storage.** The default StorageClass is gp3 on EBS (`k8s/cluster/eks/storageclass.yaml`), with
`WaitForFirstConsumer` so each volume is made in its pod's zone. An EBS volume outlives its node, unlike k3s's
local-path directories, but can only attach to a node in its own zone.

**Backups.** The EKS overlay is the k3s overlay plus patches (`kubectl kustomize` both and diff them):
- the Barman Cloud sidecar gets credentials from Pod Identity, not the static key;
- it writes to `eks/` in the bucket, the only prefix its role may write, so the EKS database can't touch the k3s
  archive (`storefront-db/`);
- a NetworkPolicy lets the Postgres pods reach the Pod Identity agent.

Until slice 3 the EKS database is a test one that starts empty every run. A previous run's archive moves to
`eks/storefront-db-previous/`, because a new database only archives into an empty folder. That has to change before
the EKS database holds the real data.

Not on EKS yet: the hourly Grafana dashboard snapshots (k3s only, and they'd need Pod Identity too), and the
`--kubelet-insecure-tls` flag kind needs on metrics-server is still set.

## What `make eks-down` cleans up

Kubernetes creates AWS resources that Terraform doesn't own:
- load balancers, target groups and security groups, from the AWS Load Balancer Controller;
- EBS volumes, from the EBS CSI driver;
- network interfaces, from the VPC CNI.

Any of the first or last left behind stops the VPC from being deleted, and a volume keeps costing money.
[scripts/eks-down.sh](../scripts/eks-down.sh) works in an order that avoids both:
1. Delete the nodes, which stops those controllers.
2. Delete the load balancers and target groups by their cluster tag.
3. Destroy the cluster. The controller adds rules to the cluster's security group that point at its own groups, and
   AWS won't delete a group something still points at. Destroying the cluster deletes that group and its rules.
4. Delete the controller's security groups and leftover network interfaces.
5. Destroy the rest.
6. Delete freed volumes tagged `storefront/cluster=storefront-eks`.

It uses AWS APIs only, so the nightly destroy runs the same script. Postgres's volumes go too, as on k3s: what
survives is its archive in S3.

## Slice 1 checked on 2026-11-21

The first `make eks-up` created all 37 resources, and every node was Ready in its zone:

- **Nodes:** one t3.medium in each of us-east-1a, 1b and 1c, on Kubernetes 1.35.9. Each allows 40 pods (the
  launch template's NodeConfig survived EKS merging in its own) and has 3,293 MiB of its 3,834 MiB allocatable.
- **Add-ons:** all five ACTIVE at the pinned versions. CoreDNS ran two replicas, on nodes in different zones, and
  every `aws-node` pod ran its NetworkPolicy agent.
- **Instance metadata:** IMDSv2 required with a hop limit of 1, and no public IPs on the nodes.
- **Storage:** a test claim got an encrypted 1 GiB gp3 volume, created through Pod Identity, tagged
  `storefront/cluster=storefront-eks`, and a pod wrote to it. So the EBS driver works with pods kept away from
  instance metadata.
- **Egress:** a pod's outbound address was the NAT gateway's.
- **NetworkPolicy:** a deny-all ingress policy blocked the next request between two pods, and removing it let
  traffic through again.

Then the nightly destroy workflow, started by hand, destroyed it in 8.5 minutes with the CI role's permissions. It
destroyed all 37 resources and deleted the test claim's volume once the nodes had freed it. Afterwards AWS had no
cluster, VPC, NAT gateway, Elastic IP, instance, tagged volume, network interface, launch template or `storefront-eks`
IAM role left. The load balancer cleanup will first run for real in slice 2, when there's a load balancer.

## Slice 2 checked on 2026-11-21

`REVISION=feat/eks-platform make eks-up` created the 46 resources. Argo CD then had every app Synced and Healthy
in 8 minutes: 54 pods across the 3 nodes, none Pending.

- **Traffic:** the controller made an internet-facing NLB on the three Terraform Elastic IPs, one per zone, with
  cross-zone load balancing on. Its targets were the two Envoy pods' IPs, on nodes in different zones, both
  healthy. `/products` answered 200 in about 0.2 s through it, and Grafana, Prometheus and Alertmanager answered on
  their sslip.io names. The NLB's security group admitted port 80 from the admin /32 and nothing else.
- **Postgres:** the primary and the replica each on an encrypted 1 GiB gp3 volume, in different zones, tagged
  `storefront/cluster=storefront-eks` for `make eks-down`.
- **Backups through Pod Identity:** EKS gave the Barman Cloud sidecar its credentials too, although Kubernetes counts
  it as an init container (a native sidecar). Continuous archiving succeeded. The first base backup was taken from
  the primary, and its WAL (segments 4 and 5) and the segment after it were in `eks/storefront-db/`.
- **NetworkPolicy:** `scripts/netpol-check.sh eks` gave every expected result. The VPC CNI's agent enforces the
  policies kube-router enforced on k3s: the database closed to everything but the app, no internet from the app,
  Prometheus scrapes allowed, `/actuator` hidden at the Gateway.
- **Memory:** pod requests were 60–71% of each node's allocatable memory, and actual use 64–73%.
- **The canary's wiring:** the Argo Rollouts Gateway API plugin controlled the HTTPRoute (stable 100, canary 0), and
  Prometheus had the recording rules the analysis queries. No canary ran, because no new image was deployed; the
  first deploy while EKS is up will run one.

The app pods restarted 3 times each at the start: they started in the same second as the database, and Flyway's
connection was refused until Postgres was up.
