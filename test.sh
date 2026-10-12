#!/bin/bash
# Publish a job's lifecycle to the FIFO topic and check both subscribers:
# - inventory only receives JobCreated/JobDeleted (filter policy) and marks
#   the job as deleted in DynamoDB
# - analytics receives all three events and archives them in S3
set -euo pipefail

STACK=${STACK_NAME:-sam-app}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-30}
JOB_ID="ci-$(date +%s)"

output() {
  lstk aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text
}

TOPIC_ARN=$(output JobEventsTopic)
BUCKET=$(output AnalyticsBucket)
PUBLISHER=$(output AntiCorruptionFunction)
TABLE=InventoryTable

echo "Invoking the anti-corruption service"
out=$(mktemp)
meta=$(lstk aws lambda invoke --function-name "$PUBLISHER" "$out")
if echo "$meta" | jq -e 'has("FunctionError")' > /dev/null; then
  echo "Test failed: anti-corruption service returned an error: $(cat "$out")"
  exit 1
fi
echo "PASS: anti-corruption service published its events"

publish() {
  local type=$1
  lstk aws sns publish --topic-arn "$TOPIC_ARN" \
    --message-group-id "JOB-$JOB_ID" \
    --message-deduplication-id "$JOB_ID-$type" \
    --message "{\"id\":\"$JOB_ID-$type\",\"jobId\":\"$JOB_ID\",\"eventCreated\":\"$(date -u +%FT%TZ)\",\"eventType\":\"$type\",\"eventSource\":\"ci\",\"eventDetails\":{}}" \
    --message-attributes "{\"eventType\":{\"DataType\":\"String\",\"StringValue\":\"$type\"}}" > /dev/null
}

echo "Publishing JobCreated, JobSalaryUpdated and JobDeleted for $JOB_ID"
publish JobCreated
publish JobSalaryUpdated
publish JobDeleted

item=""
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  item=$(lstk aws dynamodb get-item --table-name "$TABLE" --key "{\"id\":{\"S\":\"$JOB_ID\"}}" --output json | jq -c '.Item // empty')
  if echo "$item" | jq -e '.markAsDeleted.BOOL == true' > /dev/null 2>&1; then
    break
  fi
  echo "Attempt $attempt/$MAX_ATTEMPTS: inventory item not marked as deleted yet"
  sleep 2
done
if ! echo "$item" | jq -e '.eventSource.S == "ci" and .markAsDeleted.BOOL == true' > /dev/null 2>&1; then
  echo "Test failed: inventory item for $JOB_ID is ${item:-missing}"
  exit 1
fi
echo "PASS: inventory created and deleted job $JOB_ID"

# Count this job's events across the archived analytics batches
archived_types() {
  local dir
  dir=$(mktemp -d)
  lstk aws s3 cp "s3://$BUCKET/" "$dir" --recursive > /dev/null
  cat "$dir"/*/*/*/* 2>/dev/null | jq -r --arg id "$JOB_ID" '.Records[] | select(.jobId == $id) | .eventType' | sort | tr '\n' ' '
  rm -rf "$dir"
}

expected="JobCreated JobDeleted JobSalaryUpdated "
got=""
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  got=$(archived_types)
  [ "$got" = "$expected" ] && break
  echo "Attempt $attempt/$MAX_ATTEMPTS: analytics archived [${got}]"
  sleep 2
done
if [ "$got" != "$expected" ]; then
  echo "Test failed: analytics archived [${got}], expected [${expected}]"
  exit 1
fi
echo "PASS: analytics archived all three events"

echo "Test passed: events were fanned out, filtered and stored"
