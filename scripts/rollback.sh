#!/usr/bin/env bash
# Instant blue-green rollback: point the Service back at the previous colour.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPLICAS=${REPLICAS:-3}

prev=$(kubectl -n "$NS" get svc demo-bg -o jsonpath='{.metadata.annotations.demo/previous-color}' 2>/dev/null || true)
[[ -n "$prev" ]] || die "no previous colour recorded; nothing to roll back to"
cur=$(kubectl -n "$NS" get svc demo-bg -o jsonpath='{.spec.selector.color}')

log "rolling back: $cur -> $prev"
kubectl -n "$NS" scale "deployment/demo-$prev" --replicas="$REPLICAS" >/dev/null
wait_rollout "demo-$prev"
kubectl -n "$NS" patch svc demo-bg --type merge \
  -p "{\"metadata\":{\"annotations\":{\"demo/previous-color\":\"$cur\"}},\"spec\":{\"selector\":{\"color\":\"$prev\"}}}"
log "$prev is live again"
