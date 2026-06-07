# OpenClaw on Balena

Run [OpenClaw](https://github.com/openclaw/openclaw) on a Raspberry Pi 4/5 via [balenaCloud](https://balena.io). This repository provides a streamlined, appliance-optimized Balena stack featuring dynamic HAProxy routing, OTA upgrades, persistent configuration, automated RAM-buffered backups, and built-in Google Cloud CLI (`gcloud`) integration.

[![Deploy with balena](https://www.balena.io/deploy.png)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/WeatherXM/openclaw-balena)

---

## Features

- **Single-Click & OTA Deployment:** Spin up the complete stack (OpenClaw gateway, HAProxy, persistent storage) with one click or a simple `balena push`.
- **Version Snapshots & Safe Upgrades:** Manage OpenClaw versions via the `OPENCLAW_VERSION` device variable. Each release is sandboxed in `/data/openclaw/versions/<version>/`. If an installation fails, the system automatically rolls back to the previous working release.
- **Persistent Keyless Auth & Gateway Token:** Security credentials and session tokens survive container updates and purges, keeping CLI commands aligned with the Control UI.
- **Dynamic Secure Routing:** HAProxy terminates TLS for LAN connections and dynamically configures allowed origins for browser access via local IPs, `.local` domains, and Balena public URLs.
- **RAM-Buffered Backups:** A background daemon backs up configurations, memories, and plugins directly from RAM (`tmpfs`) to prevent physical microSD wear.

---

## Quick Start

1. **Deploy:** Use the deploy button above, or push manually via the Balena CLI:
   ```bash
   balena push <fleet-name>
   ```
2. **Retrieve Token:** Access the `openclaw` container logs or retrieve the generated token:
   ```bash
   cat /data/openclaw/gateway.token
   ```
3. **Connect:** Open `https://<device-ip>` (accepting the self-signed certificate) or use the Balena public URL.
4. **Approve Browser Device:** Run the following command in the container terminal if the Control UI prompts for device authorization:
   ```bash
   openclaw devices approve $(openclaw devices list | awk 'NR>1 {print $1; exit}')
   ```

---

## Configuration & Upgrades

To configure provider credentials or customize settings, open the Control UI or run the CLI utilities in the container terminal:
```bash
openclaw onboard      # Guided onboarding
openclaw configure    # Interactive configuration & model management
```
To upgrade or roll back, simply change the `OPENCLAW_VERSION` Balena device variable. Your home directory and memories are cloned and preserved across upgrades.

---

## Web UI Access & Allowed Origins

Allowed browser origins (`gateway.controlUi.allowedOrigins`) are dynamically generated on every boot. If you use a custom domain, Tailscale, or external proxies, configure these Balena Device Variables:

- **`OPENCLAW_PUBLIC_ORIGIN`**: Set to your Balena public URL (e.g., `https://<uuid>.balena-devices.com`).
- **`OPENCLAW_CONTROL_UI_ORIGINS`**: A comma-separated list of custom origins (e.g., `https://openclaw.example.com,https://my-pi.ts.net`).

> [!NOTE]
> To prioritize IPv4 for outbound API DNS resolution and avoid connection delays, set the Balena variable: `NODE_OPTIONS=--dns-result-order=ipv4first`.

---

## Device Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENCLAW_GATEWAY_TOKEN` | *Generated* | Set a static Control UI access token (overrides auto-generated tokens). |
| `OPENCLAW_PUBLIC_ORIGIN` | *None* | Single browser origin for the public URL (usually the Balena tunnel). |
| `OPENCLAW_CONTROL_UI_ORIGINS` | *None* | Comma-separated list of additional HTTPS/HTTP origins. |
| `OPENCLAW_VERSION` | *Baked release*| Target OpenClaw version to activate. |
| `OPENCLAW_KEEP_VERSIONS` | `3` | Number of sandboxed version snapshots to retain. |
| `OPENCLAW_INSTALL_GCLOUD` | `false` | Dynamically installs and configures the Google Cloud CLI (`gcloud`) on boot. |
| `NODE_OPTIONS` | *None* | Set to `--dns-result-order=ipv4first` to force IPv4 DNS lookups. |
| `OPENCLAW_ENABLE_IPV6` | `false` | Enable IPv6 literal address support in generated browser origins. |
| `HAPROXY_CERT_CN` | `openclaw.local`| Common name used in the auto-generated self-signed SSL certificate. |
| `OPENCLAW_GATEWAY_STOP` | `false` | Set to `true` to pause the gateway service for manual maintenance or repair. |

---

## Architecture

| Container | Port | Role |
| --- | --- | --- |
| **`proxy`** | `80`/`443` | HAProxy TLS termination and reverse-proxying. |
| **`openclaw`**| `8080` | OpenClaw gateway and persistent version snapshots under `/data/openclaw`. |

HAProxy automatically forwards critical routing headers (`Host`, `X-Forwarded-Proto`, `X-Forwarded-For`, `X-Real-IP`) so the gateway accurately recognizes the browser origin.

---

## Google Cloud SDK & Vertex AI

If your OpenClaw agents use Google Vertex AI (Gemini 3.x/2.5 series), enable the persistent Google Cloud CLI (`gcloud`) environment:

1. Add the Balena Device Variable **`OPENCLAW_INSTALL_GCLOUD = true`**. The container will dynamically install `gcloud` to the persistent `/data` volume on boot.
2. Set **`GOOGLE_CLOUD_PROJECT`** to your billing-enabled GCP Project ID.
3. Set **`GOOGLE_CLOUD_LOCATION`** to **`global`**.
   > [!IMPORTANT]
   > Gemini 3.x models (including `gemini-3.5-flash`, `gemini-3.1-pro`, and `gemini-3.1-flash-lite`) are **only** accessible via the `global` location endpoint on Vertex AI.

### Authentication

Credentials are saved in the persistent `/data` volume and survive container upgrades. Choose one method:

#### Method A: Google Service Account (Recommended)
1. Download your Service Account key in JSON format from GCP Console.
2. Upload it to `/data/openclaw/gcp-key.json` in the container.
3. Set the Balena Device Variable **`GOOGLE_APPLICATION_CREDENTIALS = /data/openclaw/gcp-key.json`**.

#### Method B: Interactive User Login (Development)
1. SSH into the `openclaw` container and authorize your account:
   ```bash
   gcloud auth login --no-launch-browser
   gcloud auth application-default login
   ```

---

### Pay-As-You-Go Vertex AI Embeddings (text-embedding-004)

OpenClaw's memory search is fully integrated with Google's state-of-the-art **`text-embedding-004`** model via Vertex AI using a lightweight, built-in background translation proxy. This proxy bypasses standard API formatting constraints and maps OpenAI-compatible embedding requests natively to regional Google Vertex endpoints.

To easily set up and configure Vertex AI embeddings, run the automated companion configurator inside the container terminal:

```bash
# Run the configurator in your SSH session inside the openclaw container
bash /app/setup_vertex_embeddings.sh
```

This helper script will:
1. Validate your Application Default Credentials (ADC) status.
2. Update your `openclaw.json` config file to point to the local proxy on `http://127.0.0.1:18788/v1`.
3. Check and start the background proxy daemon.
4. Automatically rebuild and verify your memory search vector database index!

You can verify the embedding health status anytime:
```bash
openclaw memory status
```

---

### Configuring Google Vertex AI Models in OpenClaw

To run keyless Gemini Vertex models, configure your active OpenClaw version's `openclaw.json` and agent profiles:

1. **Add Models** under `models.providers.google-vertex.models` (set `"api": "google-vertex"`):
   ```json
   {
     "models": {
       "providers": {
         "google-vertex": {
           "models": [
             { "id": "gemini-3.5-flash", "name": "Gemini 3.5 Flash", "api": "google-vertex" },
             { "id": "gemini-3.1-pro-preview", "name": "Gemini 3.1 Pro", "api": "google-vertex" },
             { "id": "gemini-3.1-flash-lite", "name": "Gemini 3.1 Flash Lite", "api": "google-vertex" }
           ]
         }
       }
     }
   }
   ```
2. **Set Defaults** under `agents.defaults`:
   ```json
   {
     "agents": {
       "defaults": {
         "model": "google-vertex/gemini-3.5-flash",
         "fallback": ["google-vertex/gemini-3.1-pro-preview"]
       }
     }
   }
   ```
3. **Configure Keyless Auth Profiles**:
   - In `openclaw.json`:
     ```json
     "auth": {
       "profiles": {
         "google-vertex:default": { "provider": "google-vertex", "mode": "api_key" }
       }
     }
     ```
   - In your agent's `auth-profiles.json` (at `/data/openclaw/versions/<version>/openclaw-home/.openclaw/agents/main/agent/auth-profiles.json`):
     ```json
     {
       "profiles": {
         "google-vertex:default": {
           "type": "api_key",
           "provider": "google-vertex",
           "key": "gcp-vertex-credentials"
         }
       }
     }
     ```
     > [!TIP]
     > Using `"gcp-vertex-credentials"` tells OpenClaw to bypass standard API key checks and inherit your GCP SDK / Application Default Credentials directly.

---

## Backups (Automated & Manual)

OpenClaw includes a built-in daily backup daemon. To protect microSD card lifespan, snapshots are compressed directly in RAM (`tmpfs`) and uploaded using `rclone`.

### 1. Automated Box Backups
1. Create a **Custom App** in the [Box Developer Console](https://app.box.com/developers/console) (OAuth 2.0, Redirect URI: `http://127.0.0.1:53682/`, scope: `Write all files and folders`).
2. Add Balena variables: `BOX_CLIENT_ID` and `BOX_CLIENT_SECRET`.
3. Generate your token locally (`rclone authorize "box" "<client_id>" "<client_secret>"`) and paste the JSON block into `/data/openclaw/rclone.conf` under `[box]`:
   ```ini
   [box]
   type = box
   client_id = <your_client_id>
   client_secret = <your_client_secret>
   token = {"access_token":"...","token_type":"bearer","refresh_token":"...","expiry":"..."}
   ```
4. Customize via `OPENCLAW_BACKUP_REMOTE` (default: `box`) and `OPENCLAW_BACKUP_DIR` (default: `openclaw-backups`).

### 2. Manual Backups
You can use `rclone` manually inside the container to backup the entire data directory or just the active version's config and memories:
```bash
# Configure any of rclone's 50+ supported cloud remotes
rclone config

# Backup active version's config & memories
ACTIVE_VERSION=$(cat /data/openclaw/.current-version)
rclone sync "/data/openclaw/versions/${ACTIVE_VERSION}/openclaw-home/.openclaw" remote:openclaw-home
```

---

## Local Development

To run and test the complete stack locally using Docker:
```bash
docker compose up --build
```
Once healthy, access the local proxy at `https://localhost` (accepting the self-signed certificate).

---

## License

MIT
