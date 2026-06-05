#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# OpenClaw on Balena – start script
# ---------------------------------------------------------------------------
# 1. Version management (self-contained snapshots, safe upgrades/rollbacks)
# 2. Token management (auto-generate + persist)
# 3. Config deployment (first boot only, never overwrites user edits)
# 4. Launch gateway
# ---------------------------------------------------------------------------

# ── Helpers ────────────────────────────────────────────────────────────────

has_value() {
  local val="$1"
  val="${val//[[:space:]]/}"
  [ -n "$val" ] && [[ ! "$val" =~ \$\{ ]]
}

clean_var() {
  local val="$1"
  if has_value "$val"; then
    echo "$val"
  else
    echo ""
  fi
}

is_placeholder_token() {
  local val="$1"
  val="${val//[[:space:]]/}"
  case "$val" in
    ""|changeme|CHANGE_ME|change-me|CHANGE-ME|default|DEFAULT)
      return 0
      ;;
    *'${'*|env:*)
      return 0
      ;;
  esac
  return 1
}

clean_token() {
  local val="$1"
  val="$(clean_var "$val")"
  if is_placeholder_token "$val"; then
    echo ""
  else
    echo "$val"
  fi
}

extract_version() {
  echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9a-zA-Z]+)*' | head -1
}

extract_gateway_config_token() {
  local config_path="$1"
  [ -f "$config_path" ] || return 0

  perl -0ne '
    if (/gateway\s*:\s*\{(?:(?!controlUi\s*:).)*?auth\s*:\s*\{[^{}]*token\s*:\s*"([^"]+)"/s) {
      print $1;
    }
  ' "$config_path"
}

add_origin() {
  local origin="$1"
  [ -z "$origin" ] && return 0

  local scheme rest
  case "$origin" in
    http://*)
      scheme="http://"
      rest="${origin#http://}"
      ;;
    https://*)
      scheme="https://"
      rest="${origin#https://}"
      ;;
    *) return 0 ;;
  esac

  # Browser Origin values are scheme + host + optional port only. Accept
  # pasted full URLs like https://uuid.balena-devices.com/ and normalize them.
  rest="${rest%%/*}"
  rest="${rest%%\?*}"
  rest="${rest%%\#*}"
  [ -z "$rest" ] && return 0
  origin="${scheme}${rest}"

  case ",${OPENCLAW_ORIGINS}," in
    *,"$origin",*) ;;
    *) OPENCLAW_ORIGINS="${OPENCLAW_ORIGINS}${OPENCLAW_ORIGINS:+,}${origin}" ;;
  esac
}

is_true() {
  case "$(clean_var "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

add_https_host_origins() {
  local host="$1"
  host="${host%.}"
  [ -z "$host" ] && return 0
  case "$host" in
    *[!A-Za-z0-9.-]*) return 0 ;;
  esac

  add_origin "https://${host}"
  case "$host" in
    *.*) ;;
    *) add_origin "https://${host}.local" ;;
  esac
}

build_control_ui_origins_json() {
  OPENCLAW_ORIGINS=""

  add_origin "http://127.0.0.1:8080"
  add_origin "http://localhost:8080"
  add_origin "https://127.0.0.1"
  add_origin "https://localhost"
  add_origin "https://openclaw.local"

  local hostname_value
  hostname_value="$(hostname 2>/dev/null || true)"
  hostname_value="$(clean_var "$hostname_value")"
  if [ -n "$hostname_value" ]; then
    add_https_host_origins "$hostname_value"
  fi

  local balena_name
  balena_name="$(clean_var "${BALENA_DEVICE_NAME_AT_INIT:-}")"
  if [ -n "$balena_name" ]; then
    add_https_host_origins "$balena_name"
  fi

  local balena_uuid
  balena_uuid="$(clean_var "${BALENA_DEVICE_UUID:-}")"
  if [ -n "$balena_uuid" ]; then
    add_origin "https://${balena_uuid}.balena-devices.com"
  fi

  add_origin "$(clean_var "${OPENCLAW_PUBLIC_ORIGIN:-}")"

  local ip
  for ip in $(hostname -I 2>/dev/null || true); do
    case "$ip" in
      *:*)
        if is_true "${OPENCLAW_ENABLE_IPV6:-false}"; then
          add_origin "https://[${ip}]"
        fi
        ;;
      *)
        add_origin "https://${ip}"
        ;;
    esac
  done

  local custom_origins custom_origin
  custom_origins="$(clean_var "${OPENCLAW_CONTROL_UI_ORIGINS:-}")"
  if [ -n "$custom_origins" ]; then
    IFS=',' read -ra custom_origin_list <<< "$custom_origins"
    for custom_origin in "${custom_origin_list[@]}"; do
      custom_origin="$(echo "$custom_origin" | xargs)"
      add_origin "$custom_origin"
    done
  fi

  local json="["
  local first_origin=1
  IFS=',' read -ra origin_list <<< "$OPENCLAW_ORIGINS"
  for origin in "${origin_list[@]}"; do
    [ -z "$origin" ] && continue
    if [ "$first_origin" -eq 1 ]; then
      first_origin=0
    else
      json="${json}, "
    fi
    json="${json}\"${origin}\""
  done
  json="${json}]"
  echo "$json"
}

refresh_gateway_access_config() {
  local config_path="$1"
  local origins_json="$2"
  local gateway_token="$3"

  [ -f "$config_path" ] || return 0

  ORIGINS_JSON="$origins_json" GATEWAY_TOKEN="$gateway_token" perl -0pi -e '
    my $origins = $ENV{ORIGINS_JSON};
    my $token = $ENV{GATEWAY_TOKEN};
    $token =~ s/\\/\\\\/g;
    $token =~ s/"/\\"/g;

    s/(gateway\s*:\s*\{(?:(?!controlUi\s*:).)*?auth\s*:\s*)\{[^{}]*token\s*:\s*"[^"]*"[^{}]*\}/${1}{ mode: "token", token: "$token" }/s;

    if (s/allowedOrigins\s*:\s*\[[^\]]*\]/allowedOrigins: $origins/s) {
      # replaced existing allowedOrigins
    } elsif (s/(controlUi\s*:\s*\{)/$1\n      allowedOrigins: $origins,/s) {
      # inserted into existing controlUi block
    } elsif (s/(trustedProxies\s*:\s*\[[^\]]*\]\s*,?)/$1\n    controlUi: {\n      allowedOrigins: $origins,\n      allowInsecureAuth: true,\n    },/s) {
      # inserted after trustedProxies
    }
  ' "$config_path"
}

seed_baked_openclaw() {
  local install_prefix="$1"

  if [ ! -d /usr/local/lib/node_modules/openclaw ]; then
    return 1
  fi

  mkdir -p "$install_prefix/lib/node_modules" "$install_prefix/bin"
  rm -rf "$install_prefix/lib/node_modules/openclaw"
  cp -a /usr/local/lib/node_modules/openclaw "$install_prefix/lib/node_modules/"

  local bin
  for bin in /usr/local/bin/openclaw*; do
    [ -e "$bin" ] || continue
    cp -a "$bin" "$install_prefix/bin/"
  done
}

# ── Directories ────────────────────────────────────────────────────────────

STATE_DIR="/data/openclaw"
mkdir -p "$STATE_DIR"

# Set up persistent gcloud configuration and application default credentials paths unconditionally
export CLOUDSDK_CONFIG="$STATE_DIR/.config/gcloud"
export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_CONFIG/application_default_credentials.json"
mkdir -p "$CLOUDSDK_CONFIG"

# Migrate any ephemeral gcloud credentials from previous sessions
if [ -d "/root/.config/gcloud" ] && [ ! -f "$CLOUDSDK_CONFIG/credentials.db" ]; then
  echo "Migrating existing gcloud credentials to persistent volume..."
  cp -a /root/.config/gcloud/* "$CLOUDSDK_CONFIG/" 2>/dev/null || true
  echo "✓ Migration complete"
fi

# Ensure persistent gcloud configuration environment is available in all interactive/SSH shells
for profile in /etc/bash.bashrc /etc/profile; do
  if [ -f "$profile" ] && ! grep -q "CLOUDSDK_CONFIG" "$profile"; then
    echo "export CLOUDSDK_CONFIG=\"$CLOUDSDK_CONFIG\"" >> "$profile"
    echo "export GOOGLE_APPLICATION_CREDENTIALS=\"$GOOGLE_APPLICATION_CREDENTIALS\"" >> "$profile"
  fi
done

# ── Google Cloud CLI Dynamic Installation ───────────────────────────────────

if is_true "${OPENCLAW_INSTALL_GCLOUD:-false}"; then
  GCLOUD_DIR="$STATE_DIR/google-cloud-sdk"
  if [ ! -f "$GCLOUD_DIR/bin/gcloud" ]; then
    echo "Installing Google Cloud CLI to persistent volume..."
    rm -rf "$GCLOUD_DIR" # Clean up any partial/failed installation
    
    # Detect CPU architecture
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64) GCLOUD_ARCH="x86_64" ;;
      aarch64|arm64) GCLOUD_ARCH="arm" ;;
      *) echo "Unsupported architecture for dynamic gcloud install: $ARCH"; exit 1 ;;
    esac

    GCLOUD_TAR="google-cloud-cli-linux-${GCLOUD_ARCH}.tar.gz"
    GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${GCLOUD_TAR}"

    echo "Downloading Google Cloud CLI for ${GCLOUD_ARCH}..."
    if curl -fsSL -o "/tmp/${GCLOUD_TAR}" "$GCLOUD_URL"; then
      echo "Extracting to ${STATE_DIR}..."
      tar -xf "/tmp/${GCLOUD_TAR}" -C "$STATE_DIR"
      rm "/tmp/${GCLOUD_TAR}"
      
      echo "Running gcloud installation script..."
      # Install without interactive prompts, disable usage reporting
      CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$GCLOUD_DIR/install.sh" --disable-prompts --usage-reporting=false --path-update=false
      echo "✓ Google Cloud CLI installed successfully!"
    else
      echo "Error downloading Google Cloud CLI"
    fi
  fi

  if [ -d "$GCLOUD_DIR/bin" ]; then
    export PATH="$GCLOUD_DIR/bin:$PATH"
    echo "Google Cloud CLI activated (Path: $GCLOUD_DIR/bin)"

    # Ensure gcloud CLI is available in all interactive/SSH shells
    for profile in /etc/bash.bashrc /etc/profile; do
      if [ -f "$profile" ] && ! grep -q "$GCLOUD_DIR/bin" "$profile"; then
        echo "export PATH=\"$GCLOUD_DIR/bin:\$PATH\"" >> "$profile"
      fi
    done
  fi
fi


VERSIONS_DIR="$STATE_DIR/versions"
CURRENT_VERSION_FILE="$STATE_DIR/.current-version"
KEEP_VERSIONS="${OPENCLAW_KEEP_VERSIONS:-3}"
KEEP_VERSIONS="$(clean_var "$KEEP_VERSIONS")"
KEEP_VERSIONS="${KEEP_VERSIONS:-3}"
mkdir -p "$VERSIONS_DIR"

# ── 1. Version management ──────────────────────────────────────────────────
#
# Each version is a self-contained snapshot:
#   versions/X/npm-global/    – openclaw binary + node_modules
#   versions/X/openclaw.json  – gateway config
#   versions/X/openclaw-home/ – .openclaw data (memories, skills, plugins)
#
# Upgrade: clone previous snapshot (config + home), install new binary.
# Rollback: switch to existing snapshot (everything untouched).
# Auto-prune: keep last N versions.

CURRENT_VERSION="unknown"
[ -f "$CURRENT_VERSION_FILE" ] && CURRENT_VERSION="$(cat "$CURRENT_VERSION_FILE")"

IMAGE_VERSION="$(extract_version "$(cat /app/.openclaw-image-version 2>/dev/null || true)")"
IMAGE_VERSION="${IMAGE_VERSION:-unknown}"

DESIRED_VERSION="$(clean_var "${OPENCLAW_VERSION:-}")"
DESIRED_VERSION="${DESIRED_VERSION#v}"

if [ -z "$DESIRED_VERSION" ]; then
  DESIRED_VERSION="$IMAGE_VERSION"
  echo "OpenClaw version: ${DESIRED_VERSION} (from image)"
fi

VERSION_DIR="$VERSIONS_DIR/$DESIRED_VERSION"
PREVIOUS_VERSION_DIR="$VERSIONS_DIR/$CURRENT_VERSION"

if [ "$CURRENT_VERSION" != "$DESIRED_VERSION" ]; then
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  Version change: ${CURRENT_VERSION} → ${DESIRED_VERSION}"
  echo "╚═══════════════════════════════════════════════════════════════╝"

  if [ -d "$VERSION_DIR" ]; then
    echo "Version ${DESIRED_VERSION} already installed (rollback, using existing snapshot)"
  else
    mkdir -p "$VERSION_DIR"

    if [ -d "$PREVIOUS_VERSION_DIR" ]; then
      echo "Cloning snapshot from ${CURRENT_VERSION}..."
      for item in "$PREVIOUS_VERSION_DIR"/*; do
        [ ! -e "$item" ] && continue
        basename_item="$(basename "$item")"
        [ "$basename_item" = "npm-global" ] && continue
        cp -a "$item" "$VERSION_DIR/" && echo "  cloned: ${basename_item}"
      done
      echo "✓ Snapshot cloned"
    else
      echo "Fresh install (no previous version)"
    fi

    INSTALL_PREFIX="$VERSION_DIR/npm-global"
    mkdir -p "$INSTALL_PREFIX"

    if [ "$DESIRED_VERSION" = "$IMAGE_VERSION" ] && seed_baked_openclaw "$INSTALL_PREFIX"; then
      echo "Seeded OpenClaw ${DESIRED_VERSION} from image"
    elif npm install -g --prefix "$INSTALL_PREFIX" --cache "/data/openclaw/.npm-cache" --prefer-offline --no-audit --no-fund --no-update-notifier --loglevel info "openclaw@${DESIRED_VERSION}"; then
      echo "✓ OpenClaw ${DESIRED_VERSION} installed"
    else
      echo "⚠ Offline-first install failed. Retrying online to refresh package metadata cache..."
      if npm install -g --prefix "$INSTALL_PREFIX" --cache "/data/openclaw/.npm-cache" --no-audit --no-fund --no-update-notifier --loglevel info "openclaw@${DESIRED_VERSION}"; then
        echo "✓ OpenClaw ${DESIRED_VERSION} installed successfully on online retry"
      else
        echo "⚠ Install failed"
        rm -rf "$VERSION_DIR"
        if [ -d "$PREVIOUS_VERSION_DIR" ] && [ "$CURRENT_VERSION" != "unknown" ]; then
          echo "Falling back to previous version: ${CURRENT_VERSION}"
          VERSION_DIR="$PREVIOUS_VERSION_DIR"
          DESIRED_VERSION="$CURRENT_VERSION"
        else
          echo "Falling back to image-baked version: ${IMAGE_VERSION}"
          DESIRED_VERSION="$IMAGE_VERSION"
          VERSION_DIR="$VERSIONS_DIR/$DESIRED_VERSION"
          INSTALL_PREFIX="$VERSION_DIR/npm-global"
          mkdir -p "$INSTALL_PREFIX"
          seed_baked_openclaw "$INSTALL_PREFIX"
        fi
      fi
    fi
  fi

  echo -n "$DESIRED_VERSION" > "$CURRENT_VERSION_FILE"
  touch "$VERSION_DIR" 2>/dev/null || true

  # Auto-prune old versions
  if [ "$KEEP_VERSIONS" -gt 0 ] 2>/dev/null; then
    VERSION_COUNT=$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if [ "$VERSION_COUNT" -gt "$KEEP_VERSIONS" ]; then
      echo "Pruning old versions (keeping last ${KEEP_VERSIONS})..."
      find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
        | sort -rn | tail -n +"$((KEEP_VERSIONS + 1))" | cut -d' ' -f2- \
        | while read -r old_dir; do
            old_ver="$(basename "$old_dir")"
            [ "$old_ver" != "$DESIRED_VERSION" ] && rm -rf "$old_dir" && echo "  pruned: ${old_ver}"
          done
    fi
  fi
else
  echo "OpenClaw ${CURRENT_VERSION} (already active)"
fi

# ── List installed versions ────────────────────────────────────────────────

if [ -d "$VERSIONS_DIR" ]; then
  echo "---"
  echo "Installed versions:"
  ls -1 "$VERSIONS_DIR" 2>/dev/null | while read -r ver; do
    if [ "$ver" = "$DESIRED_VERSION" ]; then
      echo "  $ver  ← active"
    else
      echo "  $ver"
    fi
  done
  echo "---"
fi

# ── Activate version snapshot ──────────────────────────────────────────────

NPM_PERSIST_DIR="$VERSION_DIR/npm-global"
mkdir -p "$NPM_PERSIST_DIR"
export PATH="${NPM_PERSIST_DIR}/bin:${PATH}"

# Symlink for docker exec convenience
LEGACY_NPM_GLOBAL="/data/openclaw/npm-global"
rm -rf "$LEGACY_NPM_GLOBAL" 2>/dev/null || true
ln -sfn "$NPM_PERSIST_DIR" "$LEGACY_NPM_GLOBAL"

# Point OpenClaw's home directly at the version snapshot directory.
# We set HOME so ~/.openclaw resolves to $VERSION_HOME/.openclaw without
# any symlinks (OpenClaw refuses symlinks in exec approval paths).
VERSION_HOME="$VERSION_DIR/openclaw-home"
mkdir -p "$VERSION_HOME"
export HOME="$VERSION_HOME"
mkdir -p "$HOME/.openclaw"
export OPENCLAW_CONFIG_PATH="$HOME/.openclaw/openclaw.json"

# One-time migration from old shared layout
OLD_HOME="/root/.openclaw"
if [ -d "$OLD_HOME" ] && [ ! -L "$OLD_HOME" ]; then
  echo "Migrating shared .openclaw to version snapshot..."
  cp -a "$OLD_HOME"/* "$HOME/.openclaw/" 2>/dev/null || true
  rm -rf "$OLD_HOME"
fi
LEGACY_CONFIG="$STATE_DIR/openclaw.json"
if [ -f "$LEGACY_CONFIG" ] && [ ! -f "$OPENCLAW_CONFIG_PATH" ]; then
  cp -a "$LEGACY_CONFIG" "$OPENCLAW_CONFIG_PATH"
fi
VERSION_CONFIG_LINK="$VERSION_DIR/openclaw.json"
if [ -f "$VERSION_CONFIG_LINK" ] && [ ! -L "$VERSION_CONFIG_LINK" ] && [ ! -f "$OPENCLAW_CONFIG_PATH" ]; then
  cp -a "$VERSION_CONFIG_LINK" "$OPENCLAW_CONFIG_PATH"
fi
ln -sfn "$OPENCLAW_CONFIG_PATH" "$VERSION_CONFIG_LINK"

# Make interactive balena terminals land on the same active OpenClaw home.
rm -rf "$OLD_HOME" 2>/dev/null || true
ln -sfn "$HOME/.openclaw" "$OLD_HOME"

echo "Active snapshot: $VERSION_DIR"

# ── 2. Gateway token ───────────────────────────────────────────────────────
#
# Chooses the first real token from:
#   1. OPENCLAW_GATEWAY_TOKEN
#   2. /data/openclaw/gateway.token
#   3. existing active gateway.auth.token
#   4. generated random token
#
# Empty values, "changeme", unresolved ${...} values, and env: SecretRef-style
# placeholders are ignored.

TOKEN_FILE="$STATE_DIR/gateway.token"
OPENCLAW_GATEWAY_TOKEN="$(clean_token "${OPENCLAW_GATEWAY_TOKEN:-}")"
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
  echo -n "$OPENCLAW_GATEWAY_TOKEN" > "$TOKEN_FILE"
  echo "Gateway token source: OPENCLAW_GATEWAY_TOKEN"
else
  if [ -f "$TOKEN_FILE" ]; then
    OPENCLAW_GATEWAY_TOKEN="$(clean_token "$(cat "$TOKEN_FILE")")"
  fi

  if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Gateway token source: $TOKEN_FILE"
  else
    OPENCLAW_GATEWAY_TOKEN="$(clean_token "$(extract_gateway_config_token "$OPENCLAW_CONFIG_PATH")")"
    if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
      echo "Gateway token source: active config"
    else
      OPENCLAW_GATEWAY_TOKEN="$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')"
      echo "Gateway token source: generated"
    fi
    echo -n "$OPENCLAW_GATEWAY_TOKEN" > "$TOKEN_FILE"
  fi
fi
export OPENCLAW_GATEWAY_TOKEN
echo "Gateway token: ${OPENCLAW_GATEWAY_TOKEN:0:16}…"

# ── 3. Config deployment ───────────────────────────────────────────────────
#
# First boot: copy static config.
# Every boot: refresh only Balena-owned gateway access fields.
# To reset config, delete the version snapshot directory and reboot.

STATIC_CONFIG="/app/openclaw.json5"
CONTROL_UI_ORIGINS_JSON="$(build_control_ui_origins_json)"

if [ ! -f "$OPENCLAW_CONFIG_PATH" ]; then
  echo "First boot: deploying config..."
  cp "$STATIC_CONFIG" "$OPENCLAW_CONFIG_PATH"
  echo "✓ Config deployed"
else
  echo "Config exists at $OPENCLAW_CONFIG_PATH (preserving user edits)"
fi

refresh_gateway_access_config "$OPENCLAW_CONFIG_PATH" "$CONTROL_UI_ORIGINS_JSON" "$OPENCLAW_GATEWAY_TOKEN"
echo "Control UI allowed origins: $CONTROL_UI_ORIGINS_JSON"

# ── SQLite Optimization for MicroSD Endurance ──────────────────────────────

if command -v sqlite3 >/dev/null 2>&1; then
  echo "Optimizing SQLite databases for microSD lifetime..."
  # Scan active OpenClaw home and persistent /data directory for databases
  find "$HOME/.openclaw" "/data" -name "*.db" -o -name "*.sqlite" 2>/dev/null | while read -r db_file; do
    # Skip any journaling auxiliary files
    [[ "$db_file" =~ -(wal|shm)$ ]] && continue
    echo "  Applying WAL mode & synchronous=NORMAL to: $db_file"
    sqlite3 "$db_file" "PRAGMA journal_mode=WAL;" "PRAGMA synchronous=NORMAL;"
  done
else
  echo "sqlite3 CLI not found – skipping database optimization"
fi

# ── 4. Launch ──────────────────────────────────────────────────────────────

# Set up persistent vertex embedding proxy
if [ -f "/app/vertex_embedding_proxy.js" ]; then
  # Always synchronize the version from the image to persistent storage
  cp -f "/app/vertex_embedding_proxy.js" "$STATE_DIR/vertex_embedding_proxy.js"
fi

# Start the local Vertex AI Embedding Proxy in the background
if [ -f "$STATE_DIR/vertex_embedding_proxy.js" ]; then
  echo "Starting local Vertex AI Embedding Proxy..."
  export NODE_PATH="${NPM_PERSIST_DIR}/lib/node_modules/openclaw/node_modules"
  node "$STATE_DIR/vertex_embedding_proxy.js" > /tmp/vertex_embedding_proxy.log 2>&1 &
  echo "✓ Local Vertex AI Embedding Proxy started"
fi

# Start the automated daily backup background daemon
/app/backup.sh &

if [ "${OPENCLAW_GATEWAY_STOP:-false}" = "true" ]; then
  echo "OPENCLAW_GATEWAY_STOP=true – skipping gateway startup"
  exec tail -f /dev/null
fi

echo "Starting OpenClaw gateway..."
exec openclaw gateway --token "$OPENCLAW_GATEWAY_TOKEN"
