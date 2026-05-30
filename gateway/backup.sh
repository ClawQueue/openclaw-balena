#!/usr/bin/env bash
set -euo pipefail

# ── OpenClaw Daily Backup Script ───────────────────────────────────────────

# Configurable variables via environment (or fallback to defaults)
REMOTE_NAME="${OPENCLAW_BACKUP_REMOTE:-box}"
BACKUP_DIR="${OPENCLAW_BACKUP_DIR:-openclaw-backups}"
BACKUP_INTERVAL_SEC=86400 # 24 hours
STATE_DIR="/data/openclaw"
TIMESTAMP_FILE="$STATE_DIR/.last-backup-timestamp"

echo "=== Backup Daemon Started ==="
echo "Target Remote: ${REMOTE_NAME}:"
echo "Target Directory: ${BACKUP_DIR}"

while true; do
  CURRENT_TIME=$(date +%s)
  LAST_BACKUP=0
  if [ -f "$TIMESTAMP_FILE" ]; then
    LAST_BACKUP=$(cat "$TIMESTAMP_FILE")
  fi

  ELAPSED=$((CURRENT_TIME - LAST_BACKUP))
  if [ "$ELAPSED" -lt "$BACKUP_INTERVAL_SEC" ]; then
    SLEEP_TIME=$((BACKUP_INTERVAL_SEC - ELAPSED))
    echo "Last backup was $((ELAPSED / 3600))h $(( (ELAPSED % 3600) / 60 ))m ago. Sleeping for $((SLEEP_TIME / 3600))h $(( (SLEEP_TIME % 3600) / 60 ))m."
    sleep "$SLEEP_TIME"
    continue
  fi

  echo "Starting daily backup process..."

  # 1. Determine active version snapshot
  if [ ! -f "$STATE_DIR/.current-version" ]; then
    echo "Error: No active version found in $STATE_DIR/.current-version. Sleeping for 10 minutes before retry."
    sleep 600
    continue
  fi
  ACTIVE_VERSION=$(cat "$STATE_DIR/.current-version")
  ACTIVE_HOME="$STATE_DIR/versions/${ACTIVE_VERSION}/openclaw-home"

  if [ ! -d "$ACTIVE_HOME" ]; then
    echo "Error: Active home directory ${ACTIVE_HOME} does not exist. Sleeping for 10 minutes before retry."
    sleep 600
    continue
  fi

  # 2. Setup temporary staging path in RAM (tmpfs) to save microSD wear!
  STAGING_DIR="/tmp/openclaw-backup-staging"
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"

  # 3. Copy critical directories and configurations
  echo "Staging critical files..."
  
  # Main JSON configuration file
  if [ -f "$ACTIVE_HOME/.openclaw/openclaw.json" ]; then
    echo "  Staging config: openclaw.json"
    cp -a "$ACTIVE_HOME/.openclaw/openclaw.json" "$STAGING_DIR/"
  fi

  # SQLite Databases (memories, flows, state, tasks)
  # Uses sqlite3 CLI backup API to avoid copying database files in inconsistent states!
  for db_dir in "memory" "flows" "plugin-state" "tasks"; do
    if [ -d "$ACTIVE_HOME/.openclaw/${db_dir}" ]; then
      mkdir -p "$STAGING_DIR/${db_dir}"
      find "$ACTIVE_HOME/.openclaw/${db_dir}" -name "*.sqlite" -o -name "*.db" 2>/dev/null | while read -r db_file; do
        db_name=$(basename "$db_file")
        if command -v sqlite3 >/dev/null 2>&1; then
          echo "  Safely backing up database: ${db_dir}/${db_name}"
          sqlite3 "$db_file" ".backup '$STAGING_DIR/${db_dir}/${db_name}'"
        else
          echo "  Copying database (sqlite3 not available): ${db_dir}/${db_name}"
          cp -a "$db_file" "$STAGING_DIR/${db_dir}/${db_name}"
        fi
      done
    fi
  done

  # User-defined skills and custom plugins
  for user_dir in "skills" "plugins"; do
    if [ -d "$ACTIVE_HOME/.openclaw/${user_dir}" ]; then
      echo "  Staging user folder: ${user_dir}"
      cp -a "$ACTIVE_HOME/.openclaw/${user_dir}" "$STAGING_DIR/"
    fi
  done

  # 4. Compress to a single ZIP file in RAM
  BACKUP_FILE_NAME="openclaw-backup-${ACTIVE_VERSION}-$(date +%Y%m%d-%H%M%S).zip"
  BACKUP_ZIP_PATH="/tmp/${BACKUP_FILE_NAME}"
  
  echo "Compressing critical files to ${BACKUP_FILE_NAME}..."
  if command -v zip >/dev/null 2>&1; then
    (cd "$STAGING_DIR" && zip -r "$BACKUP_ZIP_PATH" .) > /dev/null
  else
    echo "zip command not found! Falling back to tar.gz compression."
    BACKUP_FILE_NAME="${BACKUP_FILE_NAME%.zip}.tar.gz"
    BACKUP_ZIP_PATH="/tmp/${BACKUP_FILE_NAME}"
    (cd "$STAGING_DIR" && tar -czf "$BACKUP_ZIP_PATH" .) > /dev/null
  fi

  # Check if backup file was created successfully
  if [ ! -f "$BACKUP_ZIP_PATH" ]; then
    echo "Error: Failed to create compressed backup archive."
    rm -rf "$STAGING_DIR"
    sleep 600
    continue
  fi

  # 5. Fetch a fresh CCG access token from Box and dynamically configure rclone
  echo "Fetching Client Credentials token from Box..."
  if [ -n "${BOX_CLIENT_ID:-}" ] && [ -n "${BOX_CLIENT_SECRET:-}" ]; then
    TOKEN_JSON=$(curl -s -X POST https://api.box.com/oauth2/token \
      -d grant_type=client_credentials \
      -d client_id="$BOX_CLIENT_ID" \
      -d client_secret="$BOX_CLIENT_SECRET")
    
    TOKEN=$(echo "$TOKEN_JSON" | jq -r .access_token 2>/dev/null || true)
    
    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
      echo "✓ Successfully fetched Box token."
      export RCLONE_CONFIG_BOX_TYPE="box"
      export RCLONE_BOX_ACCESS_TOKEN="$TOKEN"
      REMOTE_NAME="box"
    else
      echo "Error: Failed to fetch Box token. Response was: $TOKEN_JSON"
      echo "Please verify that your Custom App 'Manobot#1' is fully authorized in the Box Admin Console (Custom Apps Manager)."
      rm -f "$BACKUP_ZIP_PATH"
      rm -rf "$STAGING_DIR"
      sleep 3600
      continue
    fi
  else
    echo "Error: BOX_CLIENT_ID and BOX_CLIENT_SECRET must be set as environment variables."
    rm -f "$BACKUP_ZIP_PATH"
    rm -rf "$STAGING_DIR"
    sleep 3600
    continue
  fi

  # 6. Upload using rclone
  echo "Uploading backup to ${REMOTE_NAME}:${BACKUP_DIR}..."
  if rclone copy "$BACKUP_ZIP_PATH" "${REMOTE_NAME}:${BACKUP_DIR}/"; then
    echo "✓ Backup uploaded successfully!"
    echo "$(date +%s)" > "$TIMESTAMP_FILE"
  else
    echo "Error: Upload to rclone remote failed. Checking network connectivity."
  fi

  # 7. Cleanup temporary files from RAM
  rm -f "$BACKUP_ZIP_PATH"
  rm -rf "$STAGING_DIR"

  echo "Sleeping for 24 hours..."
  sleep "$BACKUP_INTERVAL_SEC"
done
