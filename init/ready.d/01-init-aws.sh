#!/usr/bin/env bash
# Provisions all AWS practice resources once LocalStack is healthy.
# Runs automatically on container startup (LocalStack init hook) and can be
# re-run manually via `make seed` — every step is idempotent.
set -uo pipefail

REGION="us-east-1"
ACCOUNT_ID="000000000000"
BUCKET="practice-bucket"
TABLE="Orders"
QUEUE="practice-queue"
DLQ="practice-queue-dlq"
FIFO_QUEUE="practice-queue.fifo"
LOG_GROUP="/practice/app-logs"
ROLE_NAME="lambda-execution-role"
FUNCTION_NAME="hello-lambda"
TMPDIR="$(mktemp -d)"

echo "==> Provisioning IAM"
cat > "$TMPDIR/trust-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}
EOF
cat > "$TMPDIR/execution-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"], "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"]},
    {"Effect": "Allow", "Action": ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:UpdateItem"], "Resource": "arn:aws:dynamodb:*:*:table/${TABLE}*"},
    {"Effect": "Allow", "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], "Resource": "arn:aws:sqs:*:*:${QUEUE}"},
    {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "*"},
    {"Effect": "Allow", "Action": ["cloudwatch:PutMetricData"], "Resource": "*"}
  ]
}
EOF
cat > "$TMPDIR/readonly-s3-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Action": ["s3:GetObject", "s3:ListBucket"], "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"]}]
}
EOF

awslocal iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$TMPDIR/trust-policy.json" \
  >/dev/null 2>&1 && echo "  created role $ROLE_NAME" || echo "  role $ROLE_NAME already exists, skipping"
awslocal iam put-role-policy --role-name "$ROLE_NAME" --policy-name "execution-policy" \
  --policy-document "file://$TMPDIR/execution-policy.json" >/dev/null 2>&1 && echo "  attached execution-policy"

awslocal iam create-user --user-name practice-user >/dev/null 2>&1 && echo "  created user practice-user" || echo "  user practice-user already exists, skipping"
awslocal iam put-user-policy --user-name practice-user --policy-name "readonly-s3" \
  --policy-document "file://$TMPDIR/readonly-s3-policy.json" >/dev/null 2>&1 && echo "  attached readonly-s3 policy to practice-user"

echo "==> Provisioning S3"
awslocal s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  >/dev/null 2>&1 && echo "  created bucket $BUCKET" || echo "  bucket $BUCKET already exists, skipping"
awslocal s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled \
  >/dev/null 2>&1 && echo "  enabled versioning on $BUCKET"

echo "==> Provisioning DynamoDB"
awslocal dynamodb create-table \
  --table-name "$TABLE" \
  --attribute-definitions AttributeName=order_id,AttributeType=S AttributeName=created_at,AttributeType=S \
  --key-schema AttributeName=order_id,KeyType=HASH AttributeName=created_at,KeyType=RANGE \
  --global-secondary-indexes '[{"IndexName":"CreatedAtIndex","KeySchema":[{"AttributeName":"created_at","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}]' \
  --billing-mode PAY_PER_REQUEST \
  >/dev/null 2>&1 && echo "  created table $TABLE" || echo "  table $TABLE already exists, skipping"

echo "==> Provisioning SQS"
awslocal sqs create-queue --queue-name "$DLQ" >/dev/null 2>&1 && echo "  created queue $DLQ" || echo "  queue $DLQ already exists, skipping"
DLQ_ARN=$(awslocal sqs get-queue-attributes \
  --queue-url "http://localhost:4566/000000000000/$DLQ" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

REDRIVE_POLICY="{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"
awslocal sqs create-queue --queue-name "$QUEUE" \
  --attributes "{\"RedrivePolicy\":\"$(echo "$REDRIVE_POLICY" | sed 's/"/\\"/g')\",\"VisibilityTimeout\":\"5\"}" \
  >/dev/null 2>&1 && echo "  created queue $QUEUE (with redrive policy -> $DLQ)" || echo "  queue $QUEUE already exists, skipping"

awslocal sqs create-queue --queue-name "$FIFO_QUEUE" \
  --attributes '{"FifoQueue":"true","ContentBasedDeduplication":"true"}' \
  >/dev/null 2>&1 && echo "  created FIFO queue $FIFO_QUEUE" || echo "  queue $FIFO_QUEUE already exists, skipping"

echo "==> Provisioning CloudWatch"
awslocal logs create-log-group --log-group-name "$LOG_GROUP" \
  >/dev/null 2>&1 && echo "  created log group $LOG_GROUP" || echo "  log group $LOG_GROUP already exists, skipping"
awslocal cloudwatch put-metric-alarm \
  --alarm-name "practice-queue-backlog" \
  --namespace "AWS/SQS" \
  --metric-name "ApproximateNumberOfMessagesVisible" \
  --dimensions Name=QueueName,Value="$QUEUE" \
  --statistic Average --period 60 --evaluation-periods 1 \
  --threshold 5 --comparison-operator GreaterThanThreshold \
  >/dev/null 2>&1 && echo "  created alarm practice-queue-backlog"

echo "==> Provisioning Lambda"
if [ -f /opt/lambda/hello_lambda.zip ]; then
  awslocal lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --handler handler.handler \
    --role "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
    --zip-file "fileb:///opt/lambda/hello_lambda.zip" \
    --environment "Variables={BUCKET_NAME=$BUCKET,TABLE_NAME=$TABLE}" \
    >/dev/null 2>&1 && echo "  created function $FUNCTION_NAME" || echo "  function $FUNCTION_NAME already exists, skipping"

  QUEUE_ARN=$(awslocal sqs get-queue-attributes \
    --queue-url "http://localhost:4566/000000000000/$QUEUE" \
    --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
  awslocal lambda create-event-source-mapping \
    --function-name "$FUNCTION_NAME" \
    --event-source-arn "$QUEUE_ARN" \
    --batch-size 1 \
    >/dev/null 2>&1 && echo "  wired $QUEUE -> $FUNCTION_NAME event source mapping" || echo "  event source mapping already exists, skipping"
else
  echo "  WARNING: /opt/lambda/hello_lambda.zip not found — run scripts/package_lambda.sh on the host first, then 'make seed'"
fi

rm -rf "$TMPDIR"
echo "==> Init script complete"
