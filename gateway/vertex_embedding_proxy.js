const http = require('http');

// Fix Node 22 dynamic ES import bug in gaxios
globalThis.window = { fetch: globalThis.fetch };

const PORT = 18788;
const HOST = '127.0.0.1';

const server = http.createServer(async (req, res) => {
  // Set CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  if (req.method === 'POST' && (req.url === '/v1/embeddings' || req.url === '/embeddings')) {
    let body = '';
    req.on('data', chunk => {
      body += chunk.toString();
    });

    req.on('end', async () => {
      try {
        const payload = JSON.parse(body);
        let inputs = payload.input;
        if (!inputs) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: { message: 'Missing input field' } }));
          return;
        }

        // Handle single string or array of strings
        if (typeof inputs === 'string') {
          inputs = [inputs];
        }

        const modelName = payload.model || 'text-embedding-004';

        // Load GoogleGenAI
        const { GoogleGenAI } = require('@google/genai');
        const ai = new GoogleGenAI({
          vertexai: true,
          project: process.env.GOOGLE_CLOUD_PROJECT || 'gen-lang-client-0934207788',
          location: !process.env.GOOGLE_CLOUD_LOCATION || process.env.GOOGLE_CLOUD_LOCATION === 'global' ? 'us-central1' : process.env.GOOGLE_CLOUD_LOCATION
        });

        console.log(`[Proxy] Embedding ${inputs.length} inputs with model ${modelName}...`);

        const result = await ai.models.embedContent({
          model: modelName,
          contents: inputs
        });

        if (!result.embeddings) {
          throw new Error('Embeddings were not returned by Vertex AI API');
        }

        // Format into OpenAI response format
        const data = result.embeddings.map((emb, idx) => ({
          object: 'embedding',
          index: idx,
          embedding: emb.values
        }));

        const responsePayload = {
          object: 'list',
          data: data,
          model: modelName,
          usage: {
            prompt_tokens: 0,
            total_tokens: 0
          }
        };

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(responsePayload));
      } catch (err) {
        console.error('[Proxy Error]', err);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: { message: err.message || String(err) } }));
      }
    });
  } else if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'Not Found' } }));
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[Proxy] Local Vertex Embedding Proxy listening on http://${HOST}:${PORT}`);
});
