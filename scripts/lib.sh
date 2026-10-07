#!/usr/bin/env bash
# Shared helpers for the deployment scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=${NS:-demo}

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

ensure_ns() { kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

# render <template> : substitutes only the variables we own (leaves ${...} elsewhere alone)
render() {
  envsubst '${COLOR} ${TRACK} ${IMAGE} ${VERSION} ${REPLICAS} ${ERROR_RATE}' <"$1"
}

wait_rollout() { # <deployment>
  kubectl -n "$NS" rollout status "deployment/$1" --timeout="${ROLLOUT_TIMEOUT:-180s}"
}

# ---- availability probe: hammers a URL in the background and counts non-2xx ----------
PROBE_FILE=""
PROBE_PID=""
start_probe() { # <url>
  PROBE_FILE=$(mktemp)
  (
    while true; do
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 "$1" >>"$PROBE_FILE" 2>/dev/null || echo 000 >>"$PROBE_FILE"
      sleep 0.02
    done
  ) &
  PROBE_PID=$!
}

# stop_probe [allowed_failures] : prints a summary; returns non-zero if failures exceed allowance
stop_probe() {
  local allowed=${1:-0}
  kill "$PROBE_PID" 2>/dev/null || true
  wait "$PROBE_PID" 2>/dev/null || true
  local total failed
  total=$(grep -c . "$PROBE_FILE" || true)
  failed=$(grep -vc '^2' "$PROBE_FILE" || true)
  log "probe: ${total} requests, ${failed} failed"
  rm -f "$PROBE_FILE"
  if ((failed > allowed)); then
    log "FAIL: ${failed} failed requests (allowed ${allowed})"
    return 1
  fi
  log "PASS: availability $(awk -v t="$total" -v f="$failed" 'BEGIN{printf "%.3f", t? (t-f)*100/t : 0}')%"
}
