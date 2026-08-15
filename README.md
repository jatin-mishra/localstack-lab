# LocalStack Practice Lab

A local, free AWS practice environment: **IAM, S3, DynamoDB, SQS (standard + FIFO),
Lambda, CloudWatch/Logs** via [LocalStack](https://www.localstack.cloud/) Community,
plus plain **Postgres**, **Redis**, and **Elasticsearch** (+ **Kibana** UI) containers —
real engines, not AWS API emulations, since ElastiCache/RDS emulation is LocalStack
Pro-only and the OpenSearch emulation isn't the real Elasticsearch we want to practice.

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
make up            # packages the lambda zip, starts all containers, waits + seeds ES
make ps             # confirm all 5 containers are healthy (kibana can take ~60-90s)
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
| Elasticsearch | index `document_chunk_content` (`_id` = `<documentid>:<chunkid>`, fields `document_id`/`chunk_id` keyword + `content` text), seeded with 8 chunks across 3 documents |
| Kibana | UI at http://localhost:5601 (Dev Tools console; no login — security disabled) |

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

### Elasticsearch
The seeded index is `document_chunk_content` — document chunks keyed by
`_id = <documentid>:<chunkid>` with a full-text `content` field (index names must be
lowercase in ES, hence not "DocumentChunkContent").
```bash
make es-health                                             # cluster health (expect green)
curl "http://localhost:9200/document_chunk_content/_doc/doc-001:1?pretty"   # get by id
# Full-text search, BM25-scored (doc-001:1 mentions "replication" most, ranks first):
curl "http://localhost:9200/document_chunk_content/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"match":{"content":"replication"}}}'
# Exact filter on a keyword field:
curl "http://localhost:9200/document_chunk_content/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"document_id":"doc-002"}}}'
```
Reseed any time with `make seed` — idempotent: explicit `_id`s mean re-runs overwrite
the seeded docs in place, never duplicate, and your own docs are left untouched.
Restart-persistence: index a doc with your own `_id`, `make down && make up`, GET it
back — the `esdata` named volume keeps it.

### Kibana
Open http://localhost:5601 (no login — security is disabled for this lab). Dev Tools →
Console (http://localhost:5601/app/dev_tools#/console) is the interactive query console,
the ES equivalent of `make psql`. Try:
```
GET document_chunk_content/_search
{ "query": { "match": { "content": "replication" } } }
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
- **Ports already in use** — something else is bound to 4566/5432/6379/9200/5601; stop
  it or change the port mappings in `docker-compose.yml` / `.env`. Elasticsearch/Kibana
  ports default to 9200/5601 (`${ES_PORT:-9200}` / `${KIBANA_PORT:-5601}`); add
  `ES_PORT=` / `KIBANA_PORT=` lines to `.env` to override. Note host-side scripts
  (`seed_elasticsearch.sh`, `smoke_test.sh`) don't read `.env` — if you customize the
  ports, export the variable in your shell too (e.g. `ES_PORT=9201 make smoke-test`).
- **Elasticsearch exits with code 137 / Kibana very slow** — the Docker Desktop VM is
  low on memory; the ES+Kibana pair adds roughly 1.5 GB (ES has a 512 MB heap but ~1 GB
  RSS, Kibana ~500 MB). Give Docker Desktop ≥ 6 GB in Settings → Resources.
- **`vm.max_map_count` warning in ES logs** — harmless here: `discovery.type=single-node`
  demotes bootstrap checks to warnings, and Docker Desktop's Linux VM already ships with
  `vm.max_map_count=262144`.
- **Cluster health yellow** — expected on a single node for any index with replicas > 0;
  the seeded index sets `number_of_replicas: 0` (so health stays green), but indices you
  create with default settings will turn the cluster yellow. Fix with
  `"number_of_replicas": 0` in the index settings; the smoke test accepts yellow.
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
