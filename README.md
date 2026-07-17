# LocalStack Practice Lab

A local, free AWS practice environment: **IAM, S3, DynamoDB, SQS (standard + FIFO),
Lambda, CloudWatch/Logs** via [LocalStack](https://www.localstack.cloud/) Community,
plus a plain **Postgres** container (RDBMS) and **Redis** container — real engines,
not AWS API emulations, since ElastiCache/RDS emulation is LocalStack Pro-only.

## Prerequisites
- Docker + Docker Compose (confirmed: Docker 29.3, Compose v5.1)
- `zip` (ships with macOS by default)
- For host-side `awslocal`/`aws` usage (not required for `make` targets — those run
  commands inside the container):
  ```bash
  python3 -m venv .venv && source .venv/bin/activate
  pip install -r requirements.txt
  pip install "botocore[crt]"   # awscli-local needs this for its credential check
  ```
  If you have a real AWS profile configured (e.g. SSO), boto3's default credential
  chain will find it before `awslocal`'s dummy-credential fallback kicks in, and
  commands will fail with `Your session has expired` instead of hitting LocalStack.
  Fix once by adding a dedicated profile:
  ```bash
  # ~/.aws/config
  [profile localstack]
  region = us-east-1
  output = json

  # ~/.aws/credentials
  [localstack]
  aws_access_key_id = test
  aws_secret_access_key = test
  ```
  Then always run host-side commands with `AWS_PROFILE=localstack`, e.g.
  `AWS_PROFILE=localstack awslocal s3 ls`. Your `default` profile is untouched.

## Quickstart
```bash
make up            # packages the lambda zip, starts all containers, waits for readiness
make ps             # confirm all 3 containers are healthy
make smoke-test      # exercises every service end-to-end
```

The init script (`init/ready.d/01-init-aws.sh`) runs automatically once LocalStack
reports healthy and provisions everything described below. It's idempotent — re-run
it any time with `make seed` (e.g. after editing the Lambda handler).

To reset everything (wipes all data): `make clean`.

## What gets created

| Service | Resources |
|---|---|
| IAM | role `lambda-execution-role` (trust: lambda.amazonaws.com), user `practice-user` (S3 read-only policy) |
| S3 | bucket `practice-bucket`, versioning enabled |
| DynamoDB | table `Orders` (PK `order_id`, SK `created_at`) + GSI `CreatedAtIndex` |
| SQS | `practice-queue` (standard, redrive to DLQ after 3 receives), `practice-queue-dlq`, `practice-queue.fifo` (content-based dedup) |
| CloudWatch | log group `/practice/app-logs`, alarm `practice-queue-backlog` |
| Lambda | `hello-lambda` (Python 3.12), triggered by `practice-queue`, writes to DynamoDB + S3 + a custom metric |
| Postgres | `customers`, `products`, `orders`, `order_items` tables, seeded |
| Redis | empty, ready for `SET`/`GET`/`EXPIRE` practice |

All AWS commands below assume `awslocal` (from `awscli-local`, in `requirements.txt`)
or plain `aws --endpoint-url=http://localhost:4566 --region us-east-1`. If you set up
the `localstack` AWS profile above, prefix these with `AWS_PROFILE=localstack`.

## Walkthrough

### IAM
```bash
awslocal iam list-roles
awslocal iam get-role --role-name lambda-execution-role
# Prove practice-user's policy is actually scoped (implicit deny), not a rubber stamp:
awslocal iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::000000000000:user/practice-user \
  --action-names s3:PutObject
```

### S3
```bash
awslocal s3 cp README.md s3://practice-bucket/readme.txt
awslocal s3 cp README.md s3://practice-bucket/readme.txt   # overwrite -> new version
awslocal s3api list-object-versions --bucket practice-bucket --prefix readme.txt
```

### DynamoDB
```bash
awslocal dynamodb put-item --table-name Orders \
  --item '{"order_id":{"S":"o-1"},"created_at":{"S":"2026-01-01"}}'
awslocal dynamodb query --table-name Orders \
  --key-condition-expression "order_id = :o" \
  --expression-attribute-values '{":o":{"S":"o-1"}}'
# Conditional write failure (corner case):
awslocal dynamodb put-item --table-name Orders \
  --item '{"order_id":{"S":"o-1"},"created_at":{"S":"2026-01-01"}}' \
  --condition-expression "attribute_not_exists(order_id)"   # -> ConditionalCheckFailedException
```

### SQS — standard queue + DLQ redrive
`practice-queue` is also the Lambda trigger (see below) — the event source mapping
polls it continuously and will silently consume+delete your test message before it
can ever "fail" 3 times. Pause the trigger first:
```bash
UUID=$(awslocal lambda list-event-source-mappings --function-name hello-lambda --query 'EventSourceMappings[0].UUID' --output text)
awslocal lambda update-event-source-mapping --uuid "$UUID" --no-enabled
```
Now run the redrive demo:
```bash
Q=http://localhost:4566/000000000000/practice-queue
awslocal sqs send-message --queue-url $Q --message-body "hello"
awslocal sqs receive-message --queue-url $Q   # visibility timeout = 5s; receive 3x without deleting...
sleep 6
awslocal sqs receive-message --queue-url $Q
sleep 6
awslocal sqs receive-message --queue-url $Q
sleep 15   # give LocalStack a bit more time than you'd expect to actually move it
awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/practice-queue-dlq
# -> the message has moved to the DLQ after maxReceiveCount=3
```
Then re-enable the trigger: `awslocal lambda update-event-source-mapping --uuid "$UUID" --enabled`

### SQS — FIFO ordering + dedup
```bash
FQ=http://localhost:4566/000000000000/practice-queue.fifo
awslocal sqs send-message --queue-url $FQ --message-body "A" --message-group-id g1
awslocal sqs send-message --queue-url $FQ --message-body "B" --message-group-id g1
awslocal sqs send-message --queue-url $FQ --message-body "C" --message-group-id g1
awslocal sqs receive-message --queue-url $FQ   # always A first within group g1
# A group won't release its next message until the current one is deleted -
# delete A's receipt handle before receive-message returns B, then C.
awslocal sqs delete-message --queue-url $FQ --receipt-handle <ReceiptHandle from above>

# Content-based dedup: sending the same body twice within 5 min only enqueues once
awslocal sqs send-message --queue-url $FQ --message-body "dup" --message-group-id g1
awslocal sqs send-message --queue-url $FQ --message-body "dup" --message-group-id g1
```

### Lambda
```bash
awslocal lambda invoke --function-name hello-lambda \
  --payload '{"order_id":"direct-1","created_at":"2026-01-01"}' \
  out.json && cat out.json
# Note: if your local awscli is v2 (not the pip-installed v1 that awscli-local
# typically wraps), add --cli-binary-format raw-in-base64-out

# Trigger indirectly via SQS (event source mapping already wired):
awslocal sqs send-message --queue-url http://localhost:4566/000000000000/practice-queue \
  --message-body '{"order_id":"trigger-1","created_at":"2026-01-02"}'
awslocal logs tail /aws/lambda/hello-lambda --follow
```

### CloudWatch
```bash
awslocal logs describe-log-groups
awslocal logs tail /aws/lambda/hello-lambda
awslocal cloudwatch describe-alarms --alarm-names practice-queue-backlog
```
> Note: LocalStack Community doesn't actively evaluate alarm state transitions on the
> same timescale as real AWS — treat the alarm as a definition to practice creating,
> not a live-firing alarm.

### Postgres
```bash
make psql
practice=# SELECT c.name, p.name, oi.quantity
           FROM order_items oi
           JOIN orders o ON o.order_id = oi.order_id
           JOIN customers c ON c.customer_id = o.customer_id
           JOIN products p ON p.product_id = oi.product_id;
```
Restart-persistence check: insert a row, `make down && make up`, re-query — the named
volume keeps your data.

### Redis
```bash
make redis-cli
127.0.0.1:6379> SET foo bar EX 10
127.0.0.1:6379> TTL foo
127.0.0.1:6379> GET foo
```

## Troubleshooting

- **`awslocal: command not found`** — the venv from the Prerequisites section was
  never created/activated. Run `source .venv/bin/activate` first (each new shell).
- **`awslocal` fails with "Your session has expired. Please reauthenticate using
  'aws login'"** — it picked up a real (expired) AWS profile's credentials instead
  of falling back to LocalStack's dummy ones. Use the `localstack` profile described
  in Prerequisites: `AWS_PROFILE=localstack awslocal ...`.
- **Lambda invoke hangs or fails to start a container** — LocalStack's Lambda executor
  needs Docker-in-Docker access via `/var/run/docker.sock`. On macOS, open Docker
  Desktop → Settings → Advanced → enable **"Allow the default Docker socket to be
  used"**, then `make down && make up`.
- **`make seed` says the zip is missing** — run `./scripts/package_lambda.sh` first
  (or just use `make seed`, which does this automatically).
- **Ports already in use** — something else is bound to 4566/5432/6379; stop it or
  change the port mappings in `docker-compose.yml` / `.env`.
- **S3 objects vanish after `make down && make up`** — confirmed (not a timing fluke,
  tested with a generous graceful shutdown): DynamoDB, CloudWatch, and Postgres state
  all persist correctly across a restart, but S3 object data does not get written to
  `./volume/state` in this LocalStack build even with `PERSISTENCE=1`. The bucket
  itself survives (re-created idempotently by the init script) but its objects don't.
  Treat S3 objects as ephemeral for now — re-upload test objects after restarting.
- **LocalStack container exits immediately with "License activation failed"** — the
  `latest` image now requires a free `LOCALSTACK_AUTH_TOKEN` to start at all, even for
  Community/free services. Sign up free at https://app.localstack.cloud, grab your
  token, and add `LOCALSTACK_AUTH_TOKEN=<token>` to `.env`.
