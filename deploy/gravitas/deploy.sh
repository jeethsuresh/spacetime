#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${1:?Pass the immutable ghcr.io image digest}"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$server" == 'https://02fe9a55-8048-421e-a03f-eae9a4a60472.k8s.ondigitalocean.com' ]] || {
  echo 'Refusing an unexpected cluster' >&2; exit 1;
}
# These app resources are authoritative in Git. Transfer fields left owned by
# historical manual releases; runtime Secrets and namespace/RBAC are not rendered.
python3 render.py "$1" | kubectl apply --server-side --force-conflicts --field-manager=gravitas-deploy -f -
kubectl -n spacetime rollout status deployment/spacetime --timeout=300s
actual="$(kubectl -n spacetime get deployment/spacetime -o jsonpath='{.spec.template.spec.containers[0].image}')"
[[ "$actual" == "$1" ]] || { echo "Deployment image differs from the tested release" >&2; exit 1; }
python3 smoke.py https://spacetime.gravitas.cool
