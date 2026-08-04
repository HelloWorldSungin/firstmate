#!/usr/bin/env bash
# Verify the loopback OpenAI-compatible embedding endpoint and its pinned width.
set -euo pipefail

readonly endpoint=http://127.0.0.1:11434/v1/embeddings
readonly model=snowflake-arctic-embed2:568m
readonly expected_dimensions=1024

for attempt in 1 2 3 4 5; do
  response=$(curl --fail --silent --show-error --max-time 20 \
    --header 'Content-Type: application/json' \
    --data "{\"model\":\"$model\",\"input\":\"GBrain embedding health check.\"}" \
    "$endpoint") && break
  if [ "$attempt" -eq 5 ]; then
    exit 1
  fi
  sleep 1
done

dimensions=$(jq -er '.data[0].embedding | length' <<<"$response")
[ "$dimensions" -eq "$expected_dimensions" ]
