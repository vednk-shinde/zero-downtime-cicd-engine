#!/usr/bin/env bash
# Self-healing drill: kill pods and processes while traffic flows, then verify that
# Kubernetes restores the desired replica count and the service stays available.
#   scripts/chaos.sh [selector] [url]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR=${1:-app=demo-bg}
URL=${2:-http://localhost:8080}
MIN_AVAILABILITY_PCT=${MIN_AVAILABILITY_PCT:-95}

desired=$(kubectl -n "$NS" get deploy -l "$SELECTOR" -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' | awk '{s+=$1} END{print s+0}')
((desired > 1)) || die "need >1 replicas for a meaningful drill (found $desired)"

ready_count() { kubectl -n "$NS" get pods -l "$SELECTOR" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true || true; }

start_probe "$URL/api/hello"
sleep 2

log "chaos 1/2: force-deleting a random pod"
victim=$(kubectl -n "$NS" get pods -l "$SELECTOR" -o name | shuf -n1)
kubectl -n "$NS" delete "$victim" --grace-period=0 --force >/dev/null 2>&1

log "chaos 2/2: crashing 2 processes via /crash"
curl -s --max-time 2 "$URL/crash" >/dev/null || true
curl -s --max-time 2 "$URL/crash" >/dev/null || true

start=$(date +%s)
until (( $(ready_count) >= desired )); do
  (( $(date +%s) - start > 120 )) && { stop_probe 1000000 || true; die "did not self-heal within 120s"; }
  sleep 1
done
log "self-healed: ${desired}/${desired} pods Ready after $(( $(date +%s) - start ))s"

sleep 2
# Abrupt kills may drop a few in-flight requests; the contract is *availability*, not zero loss.
summary=$(stop_probe 1000000 2>&1 || true)
echo "$summary" >&2
total=$(sed -n 's/.*probe: \([0-9]*\) requests.*/\1/p' <<<"$summary")
failed=$(sed -n 's/.*requests, \([0-9]*\) failed.*/\1/p' <<<"$summary")
avail=$(awk -v t="${total:-0}" -v f="${failed:-0}" 'BEGIN{printf "%.2f", t? (t-f)*100/t : 0}')
log "availability during chaos: ${avail}% (minimum ${MIN_AVAILABILITY_PCT}%)"
awk -v a="$avail" -v m="$MIN_AVAILABILITY_PCT" 'BEGIN{exit !(a>=m)}' || die "availability below threshold"
