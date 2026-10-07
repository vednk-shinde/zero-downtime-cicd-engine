#!/usr/bin/env bash
# Progressive canary with automated analysis and rollback.
#   scripts/canary.sh <image> <version> [error_rate_for_canary]
# Traffic share == pod share, because stable and canary pods sit behind one Service.
# Env: TOTAL_REPLICAS (10) STEPS ("10 30 60 100") SAMPLES (300) MAX_ERROR_PCT (1) BASE_URL
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE=${1:?usage: canary.sh <image> <version> [error_rate]}
VERSION=${2:?usage: canary.sh <image> <version> [error_rate]}
CANARY_ERROR_RATE=${3:-0}
TOTAL=${TOTAL_REPLICAS:-10}
STEPS=${STEPS:-"10 30 60 100"}
SAMPLES=${SAMPLES:-300}
MAX_ERROR_PCT=${MAX_ERROR_PCT:-1}
BASE_URL=${BASE_URL:-http://localhost:8081}

apply() { # <track> <image> <version> <replicas> <error_rate>
  TRACK=$1 IMAGE=$2 VERSION=$3 REPLICAS=$4 ERROR_RATE=$5 render "$ROOT/k8s/canary/deployment.yaml" | kubectl apply -f - >/dev/null
}

ensure_ns
kubectl apply -f "$ROOT/k8s/canary/service.yaml" >/dev/null

if ! kubectl -n "$NS" get deployment demo-stable >/dev/null 2>&1; then
  log "no stable release yet: bootstrapping stable=$VERSION"
  apply stable "$IMAGE" "$VERSION" "$TOTAL" 0
  wait_rollout demo-stable
  exit 0
fi

stable_image=$(kubectl -n "$NS" get deployment demo-stable -o jsonpath='{.spec.template.spec.containers[0].image}')
stable_version=$(kubectl -n "$NS" get deployment demo-stable -o jsonpath='{.spec.template.metadata.labels.version}')

rollback() {
  log "ROLLBACK: removing canary, stable=$stable_version restored to $TOTAL replicas"
  kubectl -n "$NS" scale deployment/demo-canary --replicas=0 >/dev/null 2>&1 || true
  kubectl -n "$NS" scale deployment/demo-stable --replicas="$TOTAL" >/dev/null
  wait_rollout demo-stable
}

for pct in $STEPS; do
  canary_n=$(( (TOTAL * pct + 99) / 100 ))
  stable_n=$(( TOTAL - canary_n ))
  log "step ${pct}%: canary=${canary_n} stable=${stable_n} (canary version $VERSION)"

  apply canary "$IMAGE" "$VERSION" "$canary_n" "$CANARY_ERROR_RATE"
  wait_rollout demo-canary
  kubectl -n "$NS" scale deployment/demo-stable --replicas="$stable_n" >/dev/null
  sleep 3 # let endpoints settle

  # --- analysis: sample real traffic through the Service ---
  errs=0; on_canary=0
  for _ in $(seq 1 "$SAMPLES"); do
    out=$(curl -s --max-time 2 -w '\n%{http_code}' "$BASE_URL/api/hello" || printf '\n000')
    code=${out##*$'\n'}
    [[ "$code" =~ ^2 ]] || errs=$((errs + 1))
    [[ "$out" == *"\"version\":\"$VERSION\""* ]] && on_canary=$((on_canary + 1))
  done
  pct_err=$(awk -v e="$errs" -v n="$SAMPLES" 'BEGIN{printf "%.2f", e*100/n}')
  log "analysis: ${errs}/${SAMPLES} errors (${pct_err}%), ${on_canary} responses served by canary"

  if awk -v e="$pct_err" -v m="$MAX_ERROR_PCT" 'BEGIN{exit !(e>m)}'; then
    rollback
    die "canary $VERSION rejected at ${pct}% (error rate ${pct_err}% > ${MAX_ERROR_PCT}%)"
  fi
done

log "canary healthy at every step: promoting $VERSION to stable"
apply stable "$IMAGE" "$VERSION" "$TOTAL" 0
wait_rollout demo-stable
kubectl -n "$NS" scale deployment/demo-canary --replicas=0 >/dev/null
log "promoted. previous stable was $stable_version ($stable_image)"
