#!/usr/bin/env bash
# Blue-green deploy: bring up the idle colour, verify it, then flip the Service selector.
#   scripts/bluegreen.sh <image> <version>
# Env: REPLICAS (3), ERROR_RATE (0), KEEP_OLD (true => old colour stays up for instant rollback)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE=${1:?usage: bluegreen.sh <image> <version>}
VERSION=${2:?usage: bluegreen.sh <image> <version>}
REPLICAS=${REPLICAS:-3}
ERROR_RATE=${ERROR_RATE:-0}
KEEP_OLD=${KEEP_OLD:-true}
export IMAGE VERSION REPLICAS ERROR_RATE

ensure_ns
active=$(kubectl -n "$NS" get svc demo-bg -o jsonpath='{.spec.selector.color}' 2>/dev/null || true)

if [[ -z "$active" ]]; then
  log "first deploy: creating blue"
  COLOR=blue render "$ROOT/k8s/bluegreen/deployment.yaml" | kubectl apply -f -
  wait_rollout demo-blue
  COLOR=blue render "$ROOT/k8s/bluegreen/service.yaml" | kubectl apply -f -
  log "blue is live ($VERSION)"
  exit 0
fi

idle=blue
[[ "$active" == "blue" ]] && idle=green
log "active=$active -> deploying $VERSION to idle=$idle"
COLOR=$idle render "$ROOT/k8s/bluegreen/deployment.yaml" | kubectl apply -f -
# If the idle deployment already existed (previous release), force a new rollout.
kubectl -n "$NS" rollout restart "deployment/demo-$idle" >/dev/null 2>&1 || true
if ! wait_rollout "demo-$idle"; then
  kubectl -n "$NS" scale "deployment/demo-$idle" --replicas=0 >/dev/null
  die "$VERSION never became ready; $active still live"
fi

# Smoke test the idle colour *before* it receives any user traffic.
log "smoke testing demo-$idle"
kubectl -n "$NS" port-forward "deployment/demo-$idle" 18081:8080 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -fs localhost:18081/readyz >/dev/null 2>&1 && break; sleep 0.5; done
got=$(curl -fs localhost:18081/version || true)
curl -fs localhost:18081/api/hello >/dev/null || { kubectl -n "$NS" scale "deployment/demo-$idle" --replicas=0; die "smoke test failed; $active still live"; }
[[ "$got" == "$VERSION" ]] || die "idle colour reports version '$got', expected '$VERSION'"
kill $pf 2>/dev/null || true

log "switching traffic: $active -> $idle"
kubectl -n "$NS" patch svc demo-bg --type merge \
  -p "{\"metadata\":{\"annotations\":{\"demo/previous-color\":\"$active\"}},\"spec\":{\"selector\":{\"color\":\"$idle\"}}}"

if [[ "$KEEP_OLD" != "true" ]]; then
  kubectl -n "$NS" scale "deployment/demo-$active" --replicas=0
fi
log "$idle is live ($VERSION); $active kept for rollback: $KEEP_OLD"
