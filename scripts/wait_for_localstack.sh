#!/usr/bin/env bash
# Polls the LocalStack health endpoint until it reports ready, then waits
# briefly for the init/ready.d hook to finish provisioning.
set -uo pipefail

ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
MAX_WAIT=90
elapsed=0

echo "Waiting for LocalStack at $ENDPOINT ..."
until curl -sf "$ENDPOINT/_localstack/health" >/dev/null 2>&1; do
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "LocalStack did not become healthy within ${MAX_WAIT}s" >&2
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

echo "LocalStack is up. Waiting for init hook to finish provisioning..."
sleep 8
echo "Ready."
