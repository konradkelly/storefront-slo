#!/bin/bash
# Puts the lab's secrets in Parameter Store, under /storefront/, where EKS's External Secrets and k3s-up.sh read them
# (docs/eks.md, "Secrets"). Run it once, and again after changing a local file; safe to rerun.
#   bash scripts/secrets-push.sh
#
#   /storefront/slack/page-url, /storefront/slack/ticket-url   from alertmanager/secrets/slack-{page,ticket}-url
#   /storefront/grafana-cloud/url (plain), .../user, .../token  from k8s/monitoring/secrets/grafana-cloud.env
#   /storefront/db/app-password                                 generated here, once; never overwritten
#
# Values go to AWS in a request body read from a 0600 temp file, never on a command line (where `ps` would show them),
# and are never printed. SecureString parameters use the AWS-managed aws/ssm key.
#
# The database password is generated only when there's none: changing it would lock the app out of a database
# restored from the archive, until a new database sets it again. Rotating it isn't scripted yet.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_REGION=${AWS_REGION:-us-east-1}
# Git Bash rewrites any argument starting with / for Windows programs: /storefront/x would reach aws.exe as
# C:/Program Files/Git/storefront/x. The temp files' paths are converted by hand instead (native, below).
export MSYS_NO_PATHCONV=1

body=$(mktemp)
trap 'rm -f "$body"' EXIT
chmod 600 "$body"

# Windows Python and the AWS CLI don't know Git Bash's /tmp; give them Windows paths.
native() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

# put <name> <type> <value file> [overwrite]: the value comes from a file, so it's never an argument.
put() {
  python - "$1" "$2" "$(native "$3")" "${4:-true}" > "$body" <<'EOF'
import json, sys
name, kind, path, overwrite = sys.argv[1:]
value = open(path, encoding="utf-8").read().strip()
if not value:
    sys.exit(f"{path} is empty")
print(json.dumps({"Name": name, "Type": kind, "Value": value, "Overwrite": overwrite == "true"}))
EOF
  aws ssm put-parameter --cli-input-json "file://$(native "$body")" --query Version --output text | sed "s#^#$1: version #"
}

for f in slack-page-url slack-ticket-url; do
  [ -s "alertmanager/secrets/$f" ] || { echo "alertmanager/secrets/$f is missing" >&2; exit 1; }
  put "/storefront/slack/${f#slack-}" SecureString "alertmanager/secrets/$f"
done

gc_env=k8s/monitoring/secrets/grafana-cloud.env
[ -s "$gc_env" ] || { echo "$gc_env is missing (k8s/monitoring/secrets/README.md)" >&2; exit 1; }
value=$(mktemp)
trap 'rm -f "$body" "$value"' EXIT
chmod 600 "$value"
gc() { sed -n "s/^$1=//p" "$gc_env" | tr -d '\r' | tail -1 > "$value"; }
gc GRAFANA_CLOUD_PROM_URL && put /storefront/grafana-cloud/url String "$value"
gc GRAFANA_CLOUD_PROM_USER && put /storefront/grafana-cloud/user SecureString "$value"
gc GRAFANA_CLOUD_TOKEN && put /storefront/grafana-cloud/token SecureString "$value"

if aws ssm get-parameter --name /storefront/db/app-password --query Parameter.Version --output text >/dev/null 2>&1; then
  echo "/storefront/db/app-password: exists, kept"
else
  python -c 'import secrets; print(secrets.token_urlsafe(24))' > "$value"
  put /storefront/db/app-password SecureString "$value" false
fi
