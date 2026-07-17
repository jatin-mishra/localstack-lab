import json
import os
import time
import uuid

import boto3

_ls_host = os.environ.get("LOCALSTACK_HOSTNAME", "localhost")
_edge_port = os.environ.get("EDGE_PORT", "4566")
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", f"http://{_ls_host}:{_edge_port}")
REGION = os.environ.get("AWS_REGION", "us-east-1")
BUCKET = os.environ["BUCKET_NAME"]
TABLE = os.environ["TABLE_NAME"]

_session = boto3.session.Session()
s3 = _session.client("s3", endpoint_url=ENDPOINT, region_name=REGION)
dynamodb = _session.resource("dynamodb", endpoint_url=ENDPOINT, region_name=REGION)
cloudwatch = _session.client("cloudwatch", endpoint_url=ENDPOINT, region_name=REGION)


def handler(event, context):
    records = event.get("Records", [{"body": json.dumps(event)}])
    processed = []

    table = dynamodb.Table(TABLE)

    for record in records:
        body = record.get("body", "{}")
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            payload = {"raw": body}

        order_id = payload.get("order_id", str(uuid.uuid4()))
        created_at = payload.get("created_at", str(int(time.time())))

        table.put_item(Item={"order_id": order_id, "created_at": created_at, "payload": payload})

        log_key = f"logs/{order_id}-{created_at}.json"
        s3.put_object(Bucket=BUCKET, Key=log_key, Body=json.dumps(payload).encode("utf-8"))

        cloudwatch.put_metric_data(
            Namespace="Practice/HelloLambda",
            MetricData=[{"MetricName": "OrdersProcessed", "Value": 1, "Unit": "Count"}],
        )

        processed.append({"order_id": order_id, "s3_key": log_key})

    return {"statusCode": 200, "body": json.dumps({"processed": processed})}
