#!/usr/bin/env bash
# Called only after publishing and signing. No cluster credentials are needed.
set -euo pipefail
: "${IMAGE_NAME:?}" "${IMAGE_DIGEST:?}" "${SOURCE_SHA:?}"
[[ "$IMAGE_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'Invalid digest' >&2; exit 1; }
git fetch origin main
# A newer source commit supersedes this release. Never overwrite its config or
# rebase an older image promotion onto it. Its own CI will release the newer code.
if [[ $(git rev-parse origin/main) != "$SOURCE_SHA" ]]; then
  echo 'Main advanced; image is published, promotion left to the newer release.'
  exit 0
fi
python3 - <<'PY'
import os
from pathlib import Path
path = Path('k8s/overlays/kind-gitops/kustomization.yaml')
text = path.read_text()
prefix, marker, _ = text.partition('images:\n')
if not marker:
    raise SystemExit('Missing image section')
path.write_text(prefix + marker + '  - name: storefront-api\n'
                + f'    newName: {os.environ["IMAGE_NAME"]}\n'
                + f'    digest: {os.environ["IMAGE_DIGEST"]}\n')
PY
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add k8s/overlays/kind-gitops/kustomization.yaml
if git diff --cached --quiet; then exit 0; fi
git commit -m "Deploy storefront ${SOURCE_SHA:0:12} to kind"
# GITHUB_TOKEN pushes do not trigger CI again. A protected main can reject this;
# in that case promote through a reviewed PR instead of bypassing protection.
git push origin HEAD:main
