#!/usr/bin/env bash
# Blue-green deployment with automated rollback.
# Usage: bash scripts/deploy.sh <staging|production> <image>
set -euo pipefail

ENVIRONMENT="${1:-}"
IMAGE="${2:-}"

log() { echo "[deploy $(date -u +%H:%M:%S)] $*"; }

# 1. Check inputs
case "$ENVIRONMENT" in
  staging | production) ;;
  *)
    echo "Usage: $0 <staging|production> <image>" >&2
    exit 2
    ;;
esac
if [[ -z "$IMAGE" ]]; then
  echo "Error: no image given" >&2
  exit 2
fi

# 2. Load settings and create the namespace
K8S_DIR="$(cd "$(dirname "$0")/../k8s" && pwd)"
set -a
source "$K8S_DIR/$ENVIRONMENT.env"
set +a
# Allow a shorter watch on request (used when restoring the last known good version)
WATCH_SECONDS="${WATCH_OVERRIDE:-$WATCH_SECONDS}"
export IMAGE
envsubst < "$K8S_DIR/namespace.yaml" | kubectl apply -f -

# 3. Find the active colour; the new version goes to the other one
ACTIVE=$(kubectl get service web -n "$NAMESPACE" \
  -o jsonpath='{.spec.selector.colour}' 2>/dev/null || true)
if [[ "$ACTIVE" == "blue" ]]; then TARGET=green; else TARGET=blue; fi
log "Environment: $ENVIRONMENT | active: ${ACTIVE:-none} | deploying to: $TARGET"
log "Image: $IMAGE"

# 4. Deploy the new colour and wait until it is ready
export COLOUR="$TARGET"
envsubst < "$K8S_DIR/deployment.yaml" | kubectl apply -f -
if ! kubectl rollout status deployment/"web-$TARGET" -n "$NAMESPACE" --timeout=120s; then
  log "FAILED: web-$TARGET never became ready. Traffic was not switched."
  kubectl scale deployment/"web-$TARGET" -n "$NAMESPACE" --replicas=0
  exit 1
fi

# 5. Switch the Service to the new colour (the cutover)
export ACTIVE_COLOUR="$TARGET"
envsubst < "$K8S_DIR/service.yaml" | kubectl apply -f -
log "Traffic switched to $TARGET"

# 7. Rollback: point the Service back at the old colour
rollback() {
  if [[ -z "$ACTIVE" ]]; then
    log "ROLLBACK IMPOSSIBLE: no previous version in $ENVIRONMENT"
    exit 1
  fi
  export ACTIVE_COLOUR="$ACTIVE"
  envsubst < "$K8S_DIR/service.yaml" | kubectl apply -f -
  log "ROLLED BACK: traffic returned to $ACTIVE"
  exit 1
}

# 6. Watch health through the Service for the watch window
log "Watching /health for $WATCH_SECONDS seconds"
end=$(($(date +%s) + WATCH_SECONDS))
while (($(date +%s) < end)); do
  if ! kubectl exec -n "$NAMESPACE" deployment/"web-$TARGET" -- \
    wget -q -O /dev/null -T 3 http://web/health; then
    log "Health check failed"
    rollback
  fi
  sleep 5
done

# 8. Result line (our notification for now)
log "SUCCESS: $ENVIRONMENT is serving $IMAGE on $TARGET"
