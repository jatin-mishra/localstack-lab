#!/usr/bin/env bash
# Zips the sample Lambda source into a deployable artifact the init script
# picks up from inside the LocalStack container (mounted at /opt/lambda).
set -euo pipefail

cd "$(dirname "$0")/.."
rm -f lambda/hello_lambda.zip
(cd lambda/hello_lambda && zip -q -r ../hello_lambda.zip handler.py)
echo "Packaged lambda/hello_lambda.zip"
