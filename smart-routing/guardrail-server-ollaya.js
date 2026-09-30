const http = require('http');

const PORT = 3000;
const OLLAYA_URL = 'http://localhost:8787/v1/decisions';
const OLLAYA_MODEL = '@ollaya/winnow:e4b';
const TOKEN = process.env.TOKEN;

if (!TOKEN) {
  throw new Error('TOKEN env var is not set, obtain the before starting this server');
}

const CRITERIA = {
  simple: 'Simple tasks, quick factual questions, basic formatting, grammar checks, summarization, or simple text generation with no complex logic.',
  medium: 'Standard programming tasks, data extraction and processing, intermediate reasoning, detailed explanations, or content generation requiring moderate context.',
  complex: 'Highly complex logical reasoning, advanced coding architectures, multi-step planning, intricate math, deep analytical thinking, or nuanced creative synthesis.',
};

async function classifyModelUncached(messages) {
  const prompt = messages.map((m) => `${m.role}: ${m.content}`).join('\n');

  const ollayaRes = await fetch(OLLAYA_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${TOKEN}`,
    },
    body: JSON.stringify({
      model: OLLAYA_MODEL,
      state: { prompt },
      questions: {
        route: {
          type: 'choice',
          instructions: 'Classify the complexity of this prompt for routing to an LLM.',
          criteria: CRITERIA,
        },
      },
    }),
  });

  if (!ollayaRes.ok) {
    throw new Error(`Ollaya request failed: ${ollayaRes.status} ${ollayaRes.statusText}`);
  }

  const data = await ollayaRes.json();
  console.log('--- Ollaya answer ---');
  console.log(JSON.stringify(data.answers.route));

  return data.answers.route.choice;
}

// Portkey calls /check-complex and /check-medium separately per request; cache
// the classification so the second call for the same prompt is instant.
const complexityCache = new Map();
const CACHE_MAX_SIZE = 500;

async function classifyModel(messages) {
  const cacheKey = JSON.stringify(messages);

  if (complexityCache.has(cacheKey)) {
    console.log('--- Complexity cache hit ---');
    return complexityCache.get(cacheKey);
  }

  const complexity = await classifyModelUncached(messages);

  if (complexityCache.size >= CACHE_MAX_SIZE) {
    complexityCache.delete(complexityCache.keys().next().value);
  }
  complexityCache.set(cacheKey, complexity);

  return complexity;
}

function sendJson(res, statusCode, payload) {
  console.log('--- Response ---');
  console.log(JSON.stringify(payload, null, 2));
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(payload));
}

async function handleComplexityGate(res, body, targetComplexity) {
  const messages = body.request && body.request.json && body.request.json.messages;

  if (!messages) {
    sendJson(res, 400, { verdict: false, error: 'No messages found in request body' });
    return;
  }

  try {
    const complexity = await classifyModel(messages);
    console.log(`--- Classified complexity: ${complexity} (target: ${targetComplexity}) ---`);
    sendJson(res, 200, { verdict: complexity === targetComplexity });
  } catch (err) {
    console.error('Model classification failed:', err.message);
    sendJson(res, 500, { verdict: false, error: 'Model classification failed' });
  }
}

const ROUTE_HANDLERS = {
  '/check-complex': (res, body) => handleComplexityGate(res, body, 'complex'),
  '/check-medium': (res, body) => handleComplexityGate(res, body, 'medium'),
};

const server = http.createServer((req, res) => {
  let rawBody = '';

  req.on('data', (chunk) => {
    rawBody += chunk;
  });

  req.on('end', async () => {
    console.log('\n=== Incoming Request ===');
    console.log(`${req.method} ${req.url}`);

    const { pathname } = new URL(req.url, `http://${req.headers.host}`);

    const handler = ROUTE_HANDLERS[pathname];
    if (!handler) {
      sendJson(res, 404, { verdict: false, error: `Unknown route: ${pathname}` });
      return;
    }

    let body;
    try {
      body = rawBody ? JSON.parse(rawBody) : {};
    } catch (err) {
      console.error('Failed to parse JSON body:', err.message);
      sendJson(res, 400, { verdict: false, error: 'Invalid JSON body' });
      return;
    }

    await handler(res, body);
  });
});

server.listen(PORT, () => {
  console.log(`Ollaya-backed guardrail server listening on port ${PORT}`);
});
