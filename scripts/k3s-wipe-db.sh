#!/bin/bash
# Deletes the database's backups, so the next `make up` makes a new, empty database instead of restoring. The Grafana
# snapshots in the same bucket stay.
#   bash scripts/k3s-wipe-db.sh      (or: make wipe-db)
set -euo pipefail

account=$(aws sts get-caller-identity --query Account --output text)
archive="s3://storefront-k3s-backups-$account/storefront-db/"
instances=$(aws ec2 describe-instances --region us-east-1 \
  --filters Name=tag:Project,Values=storefront-pulse Name=tag:Stack,Values=k3s \
  Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -z "$instances" ] || { echo "k3s is up ($instances), and its database archives there. Run make down first."; exit 1; }
read -rp "Delete every database backup in $archive? Type delete: " answer
[ "$answer" = delete ] || { echo "Nothing deleted."; exit 1; }
aws s3 rm "$archive" --recursive --only-show-errors
echo "Deleted. The next make up starts with an empty database."
