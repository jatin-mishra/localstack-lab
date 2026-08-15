#!/usr/bin/env bash
# Waits for Elasticsearch, then idempotently creates the document_chunk_content
# index (mapping from elasticsearch/mapping.json) and bulk-loads seed_data.ndjson.
# Safe to re-run: index creation skips on resource_already_exists, and the bulk
# file uses explicit _ids so re-seeding overwrites in place instead of duplicating.
set -uo pipefail
cd "$(dirname "$0")/.."

ES="${ES_ENDPOINT:-http://localhost:${ES_PORT:-9200}}"
INDEX="document_chunk_content"
MAX_WAIT=90
elapsed=0

echo "Waiting for Elasticsearch at $ES ..."
until curl -sf "$ES/_cluster/health" >/dev/null 2>&1; do
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "Elasticsearch did not become healthy within ${MAX_WAIT}s" >&2
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

echo "==> Provisioning index $INDEX"
CREATE_BODY=$(curl -s -X PUT "$ES/$INDEX" \
  -H 'Content-Type: application/json' \
  --data-binary @elasticsearch/mapping.json)
if echo "$CREATE_BODY" | grep -q '"acknowledged":true'; then
  echo "  created index $INDEX"
elif echo "$CREATE_BODY" | grep -q 'resource_already_exists_exception'; then
  echo "  index $INDEX already exists, skipping"
else
  echo "  index creation failed: $CREATE_BODY" >&2
  exit 1
fi

echo "==> Bulk-loading seed data"
# refresh=wait_for: docs are searchable before this script exits (no smoke-test race)
BULK_BODY=$(curl -s -X POST "$ES/_bulk?refresh=wait_for" \
  -H 'Content-Type: application/x-ndjson' \
  --data-binary @elasticsearch/seed_data.ndjson)
if echo "$BULK_BODY" | grep -q '"errors":false'; then
  COUNT=$(curl -s "$ES/$INDEX/_count" | grep -o '"count":[0-9]*' | cut -d: -f2)
  echo "  bulk-seeded $INDEX (doc count: ${COUNT:-unknown})"
else
  echo "  bulk seed reported errors: $BULK_BODY" >&2
  exit 1
fi

echo "Elasticsearch ready."
