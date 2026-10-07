#!/usr/bin/env bash
# Scan the actual local image before publishing. Retain findings even on failure.
set -euo pipefail
image=${1:?Usage: scan-image.sh IMAGE REPORT_DIRECTORY}
report_dir=${2:?Usage: scan-image.sh IMAGE REPORT_DIRECTORY}
mkdir -p "$report_dir"
report_dir=$(cd "$report_dir" && pwd)
if [[ "$OSTYPE" == msys* ]]; then
  export MSYS_NO_PATHCONV=1
  report_dir=$(cd "$report_dir" && pwd -W)
fi
trivy_image=aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa
scan() {
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v storefront-trivy-cache:/root/.cache/trivy \
    -v "$report_dir:/reports" \
    "$trivy_image" image --quiet --timeout 15m "$@" "$image"
}
scan --format cyclonedx --output /reports/sbom.cdx.json
# Include unfixed HIGH/CRITICAL findings; do not silently waive vulnerabilities.
scan --scanners vuln --severity HIGH,CRITICAL --format json --output /reports/vulnerabilities.json
scan --scanners vuln --severity HIGH,CRITICAL --exit-code 1
