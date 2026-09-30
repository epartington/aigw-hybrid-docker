## Enabling Smart Routing on Prompts for Model Selection

Humans, by nature, will always pick the best model for fear of missing out on functionality. This carries a high cost for companies, since not every request requires the top model.

The problem is how to decide which model a given prompt should go to. The simplest approach is to look at prompt length — short prompts are generally simple and can be sent to a faster, lower-cost model. But sometimes you want to actually evaluate the prompt's content before deciding.

Fortunately, there's a great model called Arch-Router that is very fast and can evaluate a prompt against specific criteria to produce a routing decision.

In this example, we leverage the flexibility of the Prisma AIRS AI Gateway to check the prompt and route it to one of three models depending on its complexity.

This is a proof of concept — it leverages a local model running on my Mac — but it gives you the framework of what's possible.

It all starts with the local model. For simplicity, I'm running it on Ollama.

**Step 1: Download the model** (note: check the licensing covers your use case):

```
ollama pull fauxpaslife/arch-router:1.5b
```

**Step 2: Ensure local access.** To reach the model, I deployed a local AI Gateway instance in Docker and enabled it to access `host.docker.internal`. If you install it in Kubernetes, you'll need to amend this accordingly.

**Step 3: Configure the webhook guardrails.** Due to how this is implemented (a limitation from GCP requiring the model to be specified in the URL), you need 2 guardrails calling the same application, but at different entry points:

- `Webhook_Guardrail_Medium`: `http://host.docker.internal:3000/check-medium`
- `Webhook_Guardrail_Complex`: `http://host.docker.internal:3000/check-complex`

To create a webhook guardrail, repeat the following steps for each guardrail:

**Step 3.1: Add a new guardrail**

![Add Guardrail](./images/Add%20Guardrail.png)

**Step 3.2: Select Webhook Guardrail**

![Select Webhook Guardrail](./images/Weebhook%20Guardrail.png)

**Step 3.3: Enter the endpoint**

![Enter Webhook Endpoint](./images/Add%20webhook%20host.png)

**Step 3.4: Enable *Deny on Failure*.** This is required to return HTTP 446 if it matches.

![Enable Deny on Failure](./images/Webhook%20Guardrail.png)

**Step 4: Set up the config for testing.** Logically, you'd think a conditional config would work, but because GCP requires the model to be written in the URL, changing the model in the response doesn't work (this would probably work fine on other platforms). To work around this, we use the fallback mechanism in the AI Gateway.

```
{
	"strategy": {
		"mode": "fallback",
		"on_status_codes": [
			446
		]
	},
	"targets": [
		{
			"name": "try-complex",
			"input_guardrails": [
				"pg-webhoo-547ffe"
			],
			"provider": "@vertex",
			"override_params": {
				"model": "gemini-3.1-pro-preview"
			}
		},
		{
			"name": "try-medium",
			"input_guardrails": [
				"pg-webhoo-d3c69f"
			],
			"provider": "@vertex",
			"override_params": {
				"model": "gemini-3.7-flash"
			}
		},
		{
			"name": "default-simple",
			"provider": "@vertex",
			"override_params": {
				"model": "gemini-3.5-flash-lite"
			}
		}
	]
}
```

**Step 5: Assign it to the API key.**

**Step 6: Run the application.**

```
node guardrail-server.js
```

This listens on port 3000 for the 2 entry points. To speed things up, the application caches the request so that simple requests don't have to run through the model twice.

**Step 7: Test it out.**

Here is a sample of the output that got reclassified to simple:
```
=== Incoming Request ===
POST /check-complex
--- Headers ---
{
  "host": "host.docker.internal:3000",
  "connection": "keep-alive",
  "content-type": "application/json",
  "accept": "*/*",
  "accept-language": "*",
  "sec-fetch-mode": "cors",
  "user-agent": "node",
  "accept-encoding": "gzip, deflate",
  "content-length": "449"
}
--- Body ---
{"request":{"json":{"model":"gemini-3.1-pro-preview","messages":[{"role":"user","content":"Hello world 93"}]},"text":"Hello world 93","isStreamingRequest":false,"isTransformed":false},"response":{"json":{},"text":"","statusCode":null,"isTransformed":false},"provider":"vertex-ai","requestType":"chatComplete","metadata":{"_user":"CLI Test","agentid":"aaaaaaaa-1111-2222-3333-bbbbbbbbbb","workspace":"Main_workspace"},"eventType":"beforeRequestHook"}
--- Ollama raw response ---
{'route': 'simple'}
--- Classified complexity: simple (target: complex) ---
--- Response ---
{
  "verdict": false
}

=== Incoming Request ===
POST /check-medium
--- Headers ---
{
  "host": "host.docker.internal:3000",
  "connection": "keep-alive",
  "content-type": "application/json",
  "accept": "*/*",
  "accept-language": "*",
  "sec-fetch-mode": "cors",
  "user-agent": "node",
  "accept-encoding": "gzip, deflate",
  "content-length": "443"
}
--- Body ---
{"request":{"json":{"model":"gemini-flash-3.7","messages":[{"role":"user","content":"Hello world 93"}]},"text":"Hello world 93","isStreamingRequest":false,"isTransformed":false},"response":{"json":{},"text":"","statusCode":null,"isTransformed":false},"provider":"vertex-ai","requestType":"chatComplete","metadata":{"_user":"CLI Test","agentid":"aaaaaaaa-1111-2222-3333-bbbbbbbbbb","workspace":"Main_workspace"},"eventType":"beforeRequestHook"}
--- Complexity cache hit ---
--- Classified complexity: simple (target: medium) ---
--- Response ---
{
  "verdict": false
}
```


## Limitations

This only evaluates the prompt itself — there's no cost decision factoring in how expensive it would be to reload context vs. staying with the current model. For a much more intelligent solution, watch this space (as of early September 2026).

## How to test

```

TOKEN=$(bash /Users/mgollop/VSCode/aigw-hybrid-docker/EntraID/get-az-token.sh)

curl -s http://127.0.0.1:8787/v1/messages \
  -H "x-portkey-config: pc-webhoo-a159ef" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model": "anthropic.claude-sonnet-5", "max_tokens": 50, "messages": [{"role": "user", "content": "<simple/medium/complex prompt>"}]}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('model'))"
```
