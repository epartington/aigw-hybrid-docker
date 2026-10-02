#! /bin/bash

# Fetch the token
TOKEN=$(az account get-access-token --resource c5490456-8e83-4df6-a979-9ed2b4dd84a5 --tenant 934a04e7-6fbf-4142-83bc-4cecbacabbfb --query   "accessToken" -o tsv)

# Use the first argument ($1) if provided, otherwise default to Sonnet
MODEL="${1:-@vertex/anthropic.claude-sonnet-5}"

echo "VERTEX TEST"
echo "==========="
echo "Using model: $MODEL"

curl -k https:///localhost:18787/v1/chat/completions \
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


