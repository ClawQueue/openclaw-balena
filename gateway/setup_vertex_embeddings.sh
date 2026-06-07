#!/usr/bin/env bash
set -euo pipefail

# Helper to check if running inside the OpenClaw container
if [ ! -d "/data/openclaw" ]; then
  echo "Error: This script must be executed inside the running OpenClaw container."
  echo "Usage: balena device ssh <device-ip-or-uuid> openclaw 'bash /app/setup_vertex_embeddings.sh'"
  exit 1
fi

echo "================================================================="
echo "   OpenClaw Vertex AI Embeddings Configurator (text-embedding-004)"
echo "================================================================="

# 1. Check Application Default Credentials
ADC_PATH="/data/openclaw/.config/gcloud/application_default_credentials.json"
if [ ! -f "$ADC_PATH" ]; then
  echo "⚠ Warning: Application Default Credentials (ADC) file not found at:"
  echo "  $ADC_PATH"
  echo "  Please run 'gcloud auth application-default login' first."
  echo "-----------------------------------------------------------------"
else
  echo "✓ Application Default Credentials found"
fi

# 2. Configure OpenClaw for Vertex Embeddings
echo "Configuring OpenClaw memorySearch provider to point to local proxy..."

# Use openclaw CLI to configure keys non-interactively
openclaw config set agents.defaults.memorySearch.provider "openai-compatible" --strict-json
openclaw config set agents.defaults.memorySearch.model "text-embedding-004" --strict-json
openclaw config set agents.defaults.memorySearch.remote.baseUrl "http://127.0.0.1:18788/v1" --strict-json
openclaw config set agents.defaults.memorySearch.remote.apiKey "gcp-adc" --strict-json

echo "✓ OpenClaw memorySearch configuration updated successfully!"

# 3. Check and Restart Proxy
echo "Checking local Vertex AI Embedding Proxy daemon..."
if curl -s -f http://127.0.0.1:18788/health >/dev/null; then
  echo "✓ Local Vertex AI Embedding Proxy is running and healthy"
else
  echo "⚠ Local Vertex AI Embedding Proxy is not running."
  echo "  Starting the proxy daemon..."
  # Locate Node modules
  ACTIVE_VERSION=$(cat /data/openclaw/.current-version 2>/dev/null || echo "2026.6.1")
  export NODE_PATH="/data/openclaw/versions/${ACTIVE_VERSION}/npm-global/lib/node_modules/openclaw/node_modules"
  export GOOGLE_APPLICATION_CREDENTIALS="$ADC_PATH"
  export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-gen-lang-client-0934207788}"
  
  node /data/openclaw/vertex_embedding_proxy.js > /tmp/vertex_embedding_proxy.log 2>&1 &
  sleep 2
  
  if curl -s -f http://127.0.0.1:18788/health >/dev/null; then
    echo "✓ Local Vertex AI Embedding Proxy started successfully"
  else
    echo "❌ Error: Failed to start the local Vertex AI Embedding Proxy."
    echo "  Check logs at /tmp/vertex_embedding_proxy.log"
  fi
fi

# 4. Offer Reindexing
echo "-----------------------------------------------------------------"
echo "Rebuilding OpenClaw memory search index..."
if openclaw memory status --index --agent main; then
  echo "✓ Memory search index rebuilt successfully using text-embedding-004!"
else
  echo "❌ Error: Failed to rebuild memory search index."
fi

echo "================================================================="
echo "   Configuration Complete! text-embedding-004 is active. "
echo "================================================================="
