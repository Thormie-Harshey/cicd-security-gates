#!/usr/bin/env bash
# Smoke test: checks the app's main functions once, through the Service.
# Usage: bash scripts/smoke-test.sh <namespace>
set -euo pipefail

NAMESPACE="${1:-}"
if [[ -z "$NAMESPACE" ]]; then
  echo "Usage: $0 <namespace>" >&2
  exit 2
fi

# Send a request from inside a pod behind the Service called web
fetch() {
  kubectl exec -n "$NAMESPACE" service/web -- "$@"
}

FAILED=0
report() {
  if [[ "$2" == "pass" ]]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILED=1; fi
}

# 1. Home page returns the welcome message
body=$(fetch wget -q -O - -T 3 http://web/ || true)
[[ "$body" == *"Hello from a hardened container"* ]] && r=pass || r=fail
report "GET / returns the welcome message" "$r"

# 2. Health endpoint reports ok
body=$(fetch wget -q -O - -T 3 http://web/health || true)
[[ "$body" == *'"status":"ok"'* ]] && r=pass || r=fail
report "GET /health returns status ok" "$r"

# 3. Unknown paths return 404
headers=$(fetch wget -S -O /dev/null -T 3 http://web/does-not-exist 2>&1 || true)
[[ "$headers" == *" 404"* ]] && r=pass || r=fail
report "GET /does-not-exist returns 404" "$r"

exit "$FAILED"
