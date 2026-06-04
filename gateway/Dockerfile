FROM node:22-bookworm-slim

ARG OPENCLAW_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  tini \
  gettext-base \
  git \
  python3 \
  python3-dev \
  build-essential \
  pkg-config \
  libopus-dev \
  python3-pip \
  jq \
  rclone \
  sqlite3 \
  zip \
  && rm -rf /var/lib/apt/lists/*

# Upgrade npm to latest to ensure native builds use current npm/node-gyp tooling
RUN npm install -g npm@latest

# Install OpenClaw (pinned version or latest)
RUN if [ "$OPENCLAW_VERSION" = "latest" ]; then \
  npm install -g openclaw; \
  else \
  npm install -g "openclaw@${OPENCLAW_VERSION}"; \
  fi

# /data/openclaw/npm-global/bin is a symlink to the active per-version snapshot,
# created by start.sh at boot. This ensures docker exec shells resolve the
# correct openclaw binary even after version upgrades.
ENV PATH=/data/openclaw/google-cloud-sdk/bin:/data/openclaw/npm-global/bin:$PATH

# Performance: Node compile cache speeds up repeated CLI invocations on ARM.
# OPENCLAW_NO_RESPAWN keeps gateway restarts in-process (avoids extra process
# handoffs on small hosts). Both recommended by OpenClaw Pi docs.
ENV NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
ENV OPENCLAW_NO_RESPAWN=1
RUN mkdir -p /var/tmp/openclaw-compile-cache

WORKDIR /app

# Record the version baked into the image for runtime comparison
RUN openclaw --version 2>/dev/null | head -1 > /app/.openclaw-image-version || echo "unknown" > /app/.openclaw-image-version

COPY start.sh /app/start.sh
COPY backup.sh /app/backup.sh
COPY config/openclaw.json5 /app/openclaw.json5

RUN chmod +x /app/start.sh /app/backup.sh

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["/app/start.sh"]
