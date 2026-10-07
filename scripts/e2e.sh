#!/usr/bin/env bash
# End-to-end proof of the deployment engine on a throw-away kind cluster.
# Needs: docker, kind, kubectl, envsubst, curl.   Run: ./scripts/e2e.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLUSTER=${CLUSTER:-zdt}
BG=http://localhost:8080
CA=http://localhost:8081
v() { curl -fs "$1/version"; }

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "$ROOT/k8s/kind.yaml" --wait 120s
fi
for tag in 1.0.0 2.0.0 3.0.0; do
  docker build -q -t "demo:$tag" "$ROOT/app"
  kind load docker-image "demo:$tag" --name "$CLUSTER"
done

log "=== BLUE-GREEN ==="
"$ROOT/scripts/bluegreen.sh" demo:1.0.0 1.0.0
[[ "$(v $BG)" == "1.0.0" ]] || die "expected 1.0.0 live"

start_probe "$BG/api/hello"; sleep 2
"$ROOT/scripts/bluegreen.sh" demo:2.0.0 2.0.0
sleep 2
stop_probe 0 || die "blue-green switch dropped requests"
[[ "$(v $BG)" == "2.0.0" ]] || die "expected 2.0.0 live after switch"

start_probe "$BG/api/hello"; sleep 1
"$ROOT/scripts/rollback.sh"
sleep 2
stop_probe 0 || die "rollback dropped requests"
[[ "$(v $BG)" == "1.0.0" ]] || die "expected 1.0.0 after rollback"

log "=== BLUE-GREEN: bad release never takes traffic ==="
if ROLLOUT_TIMEOUT=30s "$ROOT/scripts/bluegreen.sh" demo:does-not-exist 9.9.9 2>/dev/null; then
  die "deploying a missing image should fail"
fi
[[ "$(v $BG)" == "1.0.0" ]] || die "failed deploy must leave 1.0.0 live"

log "=== CANARY: good release ==="
"$ROOT/scripts/canary.sh" demo:1.0.0 1.0.0                      # bootstrap stable
start_probe "$CA/api/hello"
"$ROOT/scripts/canary.sh" demo:2.0.0 2.0.0
stop_probe 0 || die "canary promotion dropped requests"
[[ "$(v $CA)" == "2.0.0" ]] || die "expected 2.0.0 promoted"

log "=== CANARY: bad release is detected and rolled back ==="
if "$ROOT/scripts/canary.sh" demo:3.0.0 3.0.0 0.5; then die "bad canary should have been rejected"; fi
for _ in $(seq 1 50); do [[ "$(v $CA)" == "2.0.0" ]] || die "users still see the bad release"; done

log "=== CHAOS: self-healing ==="
"$ROOT/scripts/chaos.sh" app=demo-canary "$CA"

log "ALL E2E CHECKS PASSED"
