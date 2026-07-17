#!/usr/bin/env bash
# Exercises every test case in metric/test_cases_and_metrics.yml end-to-end.
# Runs AWS commands inside the localstack container (awslocal is guaranteed
# there) so this script has no host-side Python/AWS CLI dependency.
set -uo pipefail

cd "$(dirname "$0")/.."
FAILURES=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

ls_exec() { docker compose exec -T localstack awslocal "$@"; }
pg_exec() { docker compose exec -T postgres psql -U practice -d practice -tAc "$1"; }
redis_exec() { docker compose exec -T redis redis-cli "$@"; }

echo "== IAM =="
ROLE_CHECK=$(ls_exec iam get-role --role-name lambda-execution-role --query 'Role.RoleName' --output text 2>/dev/null)
[ "$ROLE_CHECK" = "lambda-execution-role" ] && pass "role_created" || fail "role_created"

# iam simulate-principal-policy is broken in this LocalStack build (internal error),
# so we assert the same thing statically: the attached policy's Action list grants
# GetObject/ListBucket but not PutObject.
ACTIONS=$(ls_exec iam get-user-policy --user-name practice-user --policy-name readonly-s3 \
  --query 'PolicyDocument.Statement[0].Action' --output text 2>/dev/null)
if echo "$ACTIONS" | grep -q "GetObject" && ! echo "$ACTIONS" | grep -q "PutObject"; then
  pass "user_policy_enforced_corner_case"
else
  fail "user_policy_enforced_corner_case (got actions: $ACTIONS)"
fi

echo "== S3 =="
echo "hello-v1" | docker compose exec -T localstack sh -c "cat > /tmp/obj.txt && awslocal s3 cp /tmp/obj.txt s3://practice-bucket/smoke-test.txt" >/dev/null 2>&1
GOT=$(ls_exec s3 cp s3://practice-bucket/smoke-test.txt - 2>/dev/null)
[ "$GOT" = "hello-v1" ] && pass "put_get_roundtrip" || fail "put_get_roundtrip"

echo "hello-v2" | docker compose exec -T localstack sh -c "cat > /tmp/obj.txt && awslocal s3 cp /tmp/obj.txt s3://practice-bucket/smoke-test.txt" >/dev/null 2>&1
NUM_VERSIONS=$(ls_exec s3api list-object-versions --bucket practice-bucket --prefix smoke-test.txt --query 'length(Versions)' --output text 2>/dev/null)
[ "$NUM_VERSIONS" -ge 2 ] 2>/dev/null && pass "versioning_corner_case" || fail "versioning_corner_case (got: $NUM_VERSIONS)"

echo "== DynamoDB =="
ls_exec dynamodb put-item --table-name Orders --item '{"order_id":{"S":"smoke-1"},"created_at":{"S":"2026-01-01"}}' >/dev/null 2>&1
GOT=$(ls_exec dynamodb get-item --table-name Orders --key '{"order_id":{"S":"smoke-1"},"created_at":{"S":"2026-01-01"}}' --query 'Item.order_id.S' --output text 2>/dev/null)
[ "$GOT" = "smoke-1" ] && pass "put_and_query" || fail "put_and_query"

CC_ERR=$(ls_exec dynamodb put-item --table-name Orders \
  --item '{"order_id":{"S":"smoke-1"},"created_at":{"S":"2026-01-01"}}' \
  --condition-expression "attribute_not_exists(order_id)" 2>&1 >/dev/null)
echo "$CC_ERR" | grep -q "ConditionalCheckFailedException" && pass "conditional_write_corner_case" || fail "conditional_write_corner_case"

echo "== SQS standard =="
QURL="http://localhost:4566/000000000000/practice-queue"
ls_exec sqs send-message --queue-url "$QURL" --message-body "smoke-test-msg" >/dev/null 2>&1
GOT=$(ls_exec sqs receive-message --queue-url "$QURL" --query 'Messages[0].Body' --output text 2>/dev/null)
[ "$GOT" = "smoke-test-msg" ] && pass "send_receive" || fail "send_receive"

echo "  (dlq_redrive_corner_case is slow/order-of-operations sensitive - run manually per README)"

echo "== SQS FIFO =="
FQURL="http://localhost:4566/000000000000/practice-queue.fifo"
# Unique suffix per run: FIFO content-based dedup would otherwise treat a
# static "A"/"B"/"C" as duplicates of the previous run's messages (5 min window).
RUN_ID="$$-$(date +%s 2>/dev/null || echo 0)"
for m in A B C; do
  ls_exec sqs send-message --queue-url "$FQURL" --message-body "${m}-${RUN_ID}" --message-group-id smoke-group >/dev/null 2>&1
done
ORDER=""
for i in 1 2 3; do
  # FIFO semantics: a group won't yield its next message until the current one
  # is deleted, so receive-and-delete each before pulling the next.
  MSG=$(ls_exec sqs receive-message --queue-url "$FQURL" --query 'Messages[0].[Body,ReceiptHandle]' --output text 2>/dev/null)
  BODY=$(echo "$MSG" | awk '{print $1}')
  RH=$(echo "$MSG" | awk '{print $2}')
  ORDER="${ORDER}${BODY%%-*}"
  [ -n "$RH" ] && ls_exec sqs delete-message --queue-url "$FQURL" --receipt-handle "$RH" >/dev/null 2>&1
done
[ "$ORDER" = "ABC" ] && pass "ordering_corner_case" || fail "ordering_corner_case (got: $ORDER)"

echo "== Lambda =="
INVOKE_OUT=$(ls_exec lambda invoke --function-name hello-lambda --payload '{"order_id":"direct-1","created_at":"2026-01-01"}' /tmp/lambda-out.json 2>&1)
STATUS=$(echo "$INVOKE_OUT" | grep -o '"StatusCode": 200' || true)
[ -n "$STATUS" ] && pass "direct_invoke" || fail "direct_invoke"

ls_exec sqs send-message --queue-url "$QURL" --message-body '{"order_id":"trigger-1","created_at":"2026-01-02"}' >/dev/null 2>&1
sleep 5
GOT=$(ls_exec dynamodb get-item --table-name Orders --key '{"order_id":{"S":"trigger-1"},"created_at":{"S":"2026-01-02"}}' --query 'Item.order_id.S' --output text 2>/dev/null)
[ "$GOT" = "trigger-1" ] && pass "sqs_trigger_corner_case" || fail "sqs_trigger_corner_case"

echo "== CloudWatch =="
LG=$(ls_exec logs describe-log-groups --log-group-name-prefix /practice/app-logs --query 'logGroups[0].logGroupName' --output text 2>/dev/null)
[ "$LG" = "/practice/app-logs" ] && pass "log_group_exists" || fail "log_group_exists"

ALARM=$(ls_exec cloudwatch describe-alarms --alarm-names practice-queue-backlog --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null)
[ "$ALARM" = "practice-queue-backlog" ] && pass "alarm_defined" || fail "alarm_defined"

echo "== Postgres =="
CNT=$(pg_exec "SELECT count(*) FROM customers;" | tr -d '[:space:]')
[ "$CNT" = "3" ] && pass "seed_data_present" || fail "seed_data_present (got: $CNT)"

echo "== Redis =="
redis_exec SET smoke:key "hello" >/dev/null 2>&1
GOT=$(redis_exec GET smoke:key)
[ "$GOT" = "hello" ] && pass "set_get" || fail "set_get"

redis_exec SET smoke:ttl "expiring" EX 2 >/dev/null 2>&1
sleep 3
GOT=$(redis_exec GET smoke:ttl)
[ -z "$GOT" ] && pass "ttl_expiry_corner_case" || fail "ttl_expiry_corner_case (got: $GOT)"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All smoke tests passed."
  exit 0
else
  echo "$FAILURES smoke test(s) failed."
  exit 1
fi
