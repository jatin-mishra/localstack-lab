#!/usr/bin/env bash
# Waits for the Temporal frontend to report healthy, then idempotently registers
# a dedicated `practice` namespace (alongside the auto-created `default`).
# Safe to re-run: namespace registration is skipped if it already exists.
#
# tctl runs *inside* the temporal container (guaranteed present in the auto-setup
# image), so this script has no host-side Temporal CLI dependency — same pattern
# as smoke_test.sh shelling awslocal into the localstack container. The container
# sets TEMPORAL_CLI_ADDRESS=temporal:7233, so tctl needs no --address flag.
set -uo pipefail
cd "$(dirname "$0")/.."

NAMESPACE="practice"
RETENTION="72h"
MAX_WAIT=90
elapsed=0

tctl_exec() { docker compose exec -T temporal tctl "$@"; }

echo "Waiting for Temporal frontend to be healthy ..."
until tctl_exec cluster health >/dev/null 2>&1; do
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "Temporal did not become healthy within ${MAX_WAIT}s" >&2
    exit 1
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done

echo "==> Registering namespace '$NAMESPACE'"
if tctl_exec --namespace "$NAMESPACE" namespace describe >/dev/null 2>&1; then
  echo "  namespace $NAMESPACE already exists, skipping"
else
  if tctl_exec --namespace "$NAMESPACE" namespace register --retention "$RETENTION" >/dev/null 2>&1; then
    echo "  registered namespace $NAMESPACE (retention $RETENTION)"
  else
    echo "  namespace registration failed" >&2
    exit 1
  fi
fi

echo "Temporal ready."
