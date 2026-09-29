#! /bin/bash

# Fetch the token
TOKEN=$(az account get-access-token --query 'accessToken' -o tsv)

# Use the first argument ($1) if provided, otherwise default to Sonnet
MODEL="${1:-@vertex/anthropic.claude-sonnet-5}"

echo "VERTEX TEST"
echo "==========="
echo "Using model: $MODEL"

curl http://127.0.0.1:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
      "model": "'"$MODEL"'",
      "messages": [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "What is the tallest mountain in Victoria,Australia"}
      ],
      "max_tokens": 512
    }'


