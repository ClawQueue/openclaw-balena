# OpenClaw on Balena

Run [OpenClaw](https://github.com/openclaw/openclaw) on a Raspberry Pi 4/5 via [balenaCloud](https://balena.io). The repo provides a small Balena stack with OTA updates, rollbackable OpenClaw version snapshots, persistent config/data, and HTTPS access through HAProxy.

[![Deploy with balena](https://www.balena.io/deploy.png)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/WeatherXM/openclaw-balena)

## Goal

This project is optimized for a practical appliance-style install:

- Push once with Balena.
- Open the Control UI from LAN or the Balena public URL.
- Run `openclaw onboard` / `openclaw configure` manually when you want to add providers or change OpenClaw config.
- Upgrade or roll back OpenClaw by changing one Balena device variable.

The startup script deliberately owns only Balena-specific gateway plumbing: auth token, Control UI origins, active version, and active home/config paths. It writes the persisted gateway token into the active config so Balena terminal commands such as `openclaw onboard` work without inheriting the gateway process environment. Provider/model config remains OpenClaw-managed.

## Why This Approach

- **Single-click deployment:** use the Balena deploy button or `balena push` to provision the whole stack: OpenClaw gateway, HAProxy, persistent volumes, and public/LAN web access.
- **On-demand OpenClaw upgrades:** set `OPENCLAW_VERSION` to the release you want and restart. No reflashing, no manual npm work on the Pi.
- **Rollbackable version snapshots:** each version keeps its own OpenClaw binary, config, home data, memories, skills, and plugins under `/data/openclaw/versions/<version>/`. If an install fails, startup falls back to the previous working version. To roll back later, set `OPENCLAW_VERSION` to any retained version.
- **Keep as many rollback points as you want:** set `OPENCLAW_KEEP_VERSIONS` to the number of snapshots to retain. Higher values use more disk but give you a deeper rollback history.
- **Gateway access that survives purges and restarts:** startup ignores empty/placeholder tokens, generates a real token when needed, stores it in `/data/openclaw/gateway.token`, and keeps the active config aligned for both the web UI and Balena terminal commands.
- **Manual OpenClaw configuration remains native:** use `openclaw onboard`, `openclaw configure`, or the Control UI. The scripts do not try to rewrite provider/model config for you.
- **Back up the whole appliance or just memories:** `rclone` is built in, so you can sync `/data/openclaw` or a narrower directory such as the active `.openclaw` memory data to Dropbox, Google Drive, Box, S3, WebDAV, and many other remotes.
- **Balena operations are still available:** remote logs, terminal access, device variables, public URL, OTA release updates, fleet management, and container restarts all work through the Balena dashboard/CLI.
- **Local and tunnel UI support:** HAProxy handles LAN HTTPS and the Balena public URL, while startup regenerates OpenClaw Control UI origins for the current device, tunnel, LAN IPs, and any custom origin you provide.
- **IPv4-first defaults:** IPv6 is off by default to avoid Raspberry Pi/LAN edge cases with browser origins, self-signed certificates, and mixed tunnel/LAN access. Users who need IPv6 can opt in explicitly.

## Quick Start

Deploy with the button above, or push manually:

```bash
balena push <username>/<fleet-name>
```

On a clean device, first boot does this automatically:

1. Creates `/data/openclaw/versions/<version>/`.
2. Seeds the image-baked OpenClaw binary into that snapshot, or installs `OPENCLAW_VERSION` if you set one.
3. Generates a gateway token unless a real `OPENCLAW_GATEWAY_TOKEN` was provided.
4. Persists that token at `/data/openclaw/gateway.token`.
5. Writes the token and browser origins into the active config.
6. Starts the OpenClaw gateway behind HAProxy.

Find the token in the `openclaw` service logs:

```bash
balena device logs <device-uuid> --service openclaw
```

Look for:

```text
Gateway token source: generated
Gateway token: <first-16-chars>…
```

If you need the full token, open the Balena terminal for the `openclaw` container and run:

```bash
cat /data/openclaw/gateway.token
```

Then open:

- LAN: `https://<device-ip>` and accept the self-signed certificate.
- Balena public URL: `https://<device-uuid>.balena-devices.com/`.

Use the gateway token to log in. Later, if you want Balena to own the token explicitly, set `OPENCLAW_GATEWAY_TOKEN` to that value as a Balena device variable.

On first browser login over the Balena tunnel or LAN, OpenClaw may also require one-time device approval. This is separate from the gateway token. In the Balena terminal:

```bash
openclaw devices list
openclaw devices approve <request-id>
```

If the UI keeps asking, refresh the page and re-run `openclaw devices list`; browser retries can supersede an old request with a new request ID.

## Configure OpenClaw

After the gateway is running, use the Balena terminal or SSH into the `openclaw` container:

```bash
openclaw onboard
openclaw configure
```

The container keeps `/root/.openclaw` pointed at the active version snapshot, so manual commands use the same config and home directory as the running gateway. You can also edit config from the Control UI.

The expected clean-install sequence is:

1. Deploy and wait until the `openclaw` logs show `ready`.
2. Read `/data/openclaw/gateway.token` or set your own token in `OPENCLAW_GATEWAY_TOKEN`.
3. Open the Control UI through the Balena public URL or LAN URL.
4. Enter the gateway token.
5. Approve the browser device once with `openclaw devices approve <request-id>`.
6. Run `openclaw onboard` or use the Control UI config tools to add providers/models.

No script edits provider keys, models, or OpenClaw agent config programmatically.

## Web UI Access

The gateway uses token auth and a regenerated `gateway.controlUi.allowedOrigins` list on every boot. The generated list includes:

- `https://localhost`, `https://127.0.0.1`, and direct gateway loopback origins.
- The container hostname and `.local` hostname where valid.
- Current device IPv4 addresses from `hostname -I`.
- `https://<BALENA_DEVICE_UUID>.balena-devices.com` when Balena exposes the UUID.
- `OPENCLAW_PUBLIC_ORIGIN` when set.
- Any comma-separated values in `OPENCLAW_CONTROL_UI_ORIGINS`.

For the Balena public device URL, you can paste the tunnel URL directly:

```text
OPENCLAW_PUBLIC_ORIGIN=https://<device-uuid>.balena-devices.com/
```

Trailing slashes and paths are normalized away because browsers send origins as `scheme://host[:port]`.

For multiple custom origins such as DNS, Tailscale, or another reverse proxy, set:

```text
OPENCLAW_CONTROL_UI_ORIGINS=https://openclaw.example.com,https://my-pi.ts.net
```

Avoid `allowedOrigins: ["*"]`; OpenClaw treats that as a real browser-origin allow-all policy.

IPv6 is disabled by default. HAProxy binds to `0.0.0.0` only, and startup does not add IPv6 literal addresses to OpenClaw's allowed origins. If you need IPv6:

1. Set `OPENCLAW_ENABLE_IPV6=true`.
2. Add your IPv6 browser origin explicitly, using brackets:

```text
OPENCLAW_CONTROL_UI_ORIGINS=https://[2001:db8::1234]
```

3. Update `proxy/haproxy.cfg` to bind IPv6 as well, for example `bind :::80 v4v6` and `bind :::443 v4v6 ssl crt /etc/haproxy/certs/self-signed.pem`.

If you are not using IPv6 and see Node/OpenClaw outbound connection delays or failures caused by IPv6 DNS results, you can set this Balena device variable:

```text
NODE_OPTIONS=--dns-result-order=ipv4first
```

Balena passes it into the container automatically. It makes Node prefer IPv4 for DNS results used by OpenClaw, but it does not control HAProxy bind addresses or browser allowed origins.

## Upgrades And Rollback

Each OpenClaw version is a self-contained snapshot under `/data/openclaw/versions/<version>/`:

```text
npm-global/       # openclaw binary + node_modules
openclaw.json     # symlink to openclaw-home/.openclaw/openclaw.json
openclaw-home/    # active HOME; contains .openclaw data, config, memories, skills, plugins
```

To upgrade, set `OPENCLAW_VERSION` to a release such as `2026.5.22` and restart the container. The previous snapshot is cloned, the target OpenClaw package is installed into the new snapshot, and the gateway starts from that snapshot.

If installation fails, startup falls back to the previous installed version. On a fresh device with no previous snapshot, it falls back to the image-baked OpenClaw version.

To roll back, set `OPENCLAW_VERSION` to an already installed version and restart. That snapshot is activated as-is, including the OpenClaw binary, config, home data, memories, skills, and plugins from that version.

Old snapshots are pruned by modification time. Set `OPENCLAW_KEEP_VERSIONS` to control how many are kept; default is `3`. Set a larger number if you want a deeper rollback history.

## Device Variables

| Variable | Purpose |
| --- | --- |
| `OPENCLAW_GATEWAY_TOKEN` | Control UI token. Empty, unresolved placeholders, and `changeme` are ignored; startup uses the persisted token file or generates one. |
| `OPENCLAW_PUBLIC_ORIGIN` | Single browser origin for the public UI URL, usually the Balena tunnel URL. |
| `OPENCLAW_CONTROL_UI_ORIGINS` | Extra comma-separated HTTPS/HTTP origins for custom DNS, Tailscale, or another proxy. |
| `OPENCLAW_ENABLE_IPV6` | Set `true` to include IPv6 literal addresses in generated origins. HAProxy still needs IPv6 bind lines if you want direct IPv6 access. Default: `false`. |
| `NODE_OPTIONS` | Optional Node runtime flags. `--dns-result-order=ipv4first` is useful when you want OpenClaw outbound DNS to prefer IPv4. |
| `OPENCLAW_VERSION` | OpenClaw version to activate. Empty uses the image-baked version. |
| `OPENCLAW_KEEP_VERSIONS` | Number of version snapshots to keep. Default: `3`. |
| `OPENCLAW_GATEWAY_STOP` | Set `true` to keep the container alive without starting the gateway. Useful for repair. |
| `OPENCLAW_INSTALL_GCLOUD` | Set `true` to dynamically install Google Cloud CLI (`gcloud`) in the persistent `/data` volume. Installs once and persists across container updates. Default: `false`. |
| `HAPROXY_CERT_CN` | Common name for the generated self-signed certificate. Default: `openclaw.local`. |

## Architecture

| Container | Role |
| --- | --- |
| `proxy` | HAProxy TLS termination on ports 80/443. Balena public URL traffic on port 80 is forwarded without redirect because Balena terminates TLS upstream. |
| `openclaw` | OpenClaw gateway on port 8080 with persistent version snapshots under `/data/openclaw`. |

HAProxy forwards `Host`, `X-Forwarded-Proto`, `X-Forwarded-For`, and `X-Real-IP` so OpenClaw sees the browser-facing origin.

## Google Cloud CLI (gcloud)

If your OpenClaw skills, plugins, or workflows require `gcloud` (Google Cloud CLI) to be available inside the gateway environment:

1. Add the Balena device variable `OPENCLAW_INSTALL_GCLOUD` with the value `true` in your Balena Cloud dashboard.
2. On boot, the container will automatically download the correct package for your host's architecture (AMD64 or ARM64) and install it to the persistent `/data` volume. It only installs once and has zero boot-time overhead on subsequent restarts.

### GCP Authentication and Configuration

To use `gcloud` or GCP Client Libraries in your OpenClaw skills and plugins, you need to configure authentication and target details. 

#### 1. Configure GCP Project & Location
You can set your default Google Cloud target details by defining them as **Balena Device Variables** in your Balena Cloud dashboard. They will automatically be injected into your container's environment:

* **Name/Key:** `GOOGLE_CLOUD_PROJECT`  
  **Value:** Your GCP Project ID (e.g., `my-gcp-project`)
* **Name/Key:** `GOOGLE_CLOUD_LOCATION`  
  **Value:** Your target GCP Region/Location (e.g., `europe-west4` or `us-central1`)

#### 2. Authentication Options

Choose one of the following methods to authenticate inside the container:

##### Method A: Google Service Account (Recommended for production)
This is the cleanest and most secure method for headless appliances:
1. In your Google Cloud Console, create a Service Account with the required IAM roles and download its private key in **JSON format**.
2. Upload or save that file as `/data/openclaw/gcp-key.json` inside your container (you can create/paste it via the Balena SSH terminal, or copy it via `scp`/`rclone`).
3. Add the following **Balena Device Variable** in your dashboard:
   * **Name/Key:** `GOOGLE_APPLICATION_CREDENTIALS`
   * **Value:** `/data/openclaw/gcp-key.json`

Because `/data` is a persistent volume, your credentials are safe, private, and will survive all future container upgrades.

##### Method B: Interactive User Login (Web-flow with Persistent Store)
For development, you can log in interactively using your Google account. Both your gcloud CLI tokens and Google client Application Default Credentials (ADC) are stored under `/data/openclaw/.config/gcloud` on your persistent volume, ensuring they persist cleanly across gateway restarts and version upgrades:

1. SSH/Open Terminal into your `openclaw` container via Balena Cloud:
   ```bash
   balena device ssh <device_uuid> openclaw
   ```
2. Authenticate the `gcloud` CLI:
   ```bash
   gcloud auth login --no-launch-browser
   ```
   Copy the URL shown, sign in via your browser, and paste the authorization code back.
3. **Mandatory for Vertex AI**: Generate the **Application Default Credentials (ADC)** file needed by OpenClaw's Node.js Vertex transport client:
   ```bash
   gcloud auth application-default login
   ```
   Follow the same URL/browser web-flow. This writes `application_default_credentials.json` directly into `/data/openclaw/.config/gcloud/application_default_credentials.json`, which is permanently shared with the gateway service.

### Updating gcloud

To update the Google Cloud SDK, open the container terminal in Balena Cloud and run:
```bash
gcloud components update
```

Or to force a clean re-installation, delete the directory from the terminal and restart the container:
```bash
rm -rf /data/openclaw/google-cloud-sdk
```

### GCP & Vertex AI Integration Key Learnings

When deploying OpenClaw on Balena with Google Vertex AI, keep these architectural and behavior-specific conclusions in mind for a reliable and repeatable configuration:

1. **Location & Region Constraints (The 404 NOT_FOUND Trap)**
   - The newer Gemini 3.x series models on Vertex AI (e.g., `gemini-3.5-flash`, `gemini-3.1-pro-preview`, and `gemini-3.1-flash-lite`) are currently only published on the Google Cloud **`global`** endpoint.
   - Targeting a regional location like `us-central1` or `europe-west3` for these models will result in a `404 NOT_FOUND` error stating *"Publisher Model was not found or your project does not have access to it"*.
   - **Solution**: Always set your regional location environment variable `GOOGLE_CLOUD_LOCATION` to `global` when working with the 3.x series.

2. **Project-ID Selection & API Scope**
   - Google AI Studio auto-generated development projects (which start with `gen-lang-client-`) work perfectly for Vertex AI integration if Vertex AI is enabled.
   - Standard Google Cloud user-created projects work identically, provided you have billing enabled on that specific project.
   - Ensure the project environment variables `GOOGLE_CLOUD_PROJECT` and `GCLOUD_PROJECT` are consistently configured to match the active project.

3. **Application Default Credentials (ADC) Behavior**
   - When running `gcloud auth application-default login` inside the container, gcloud might default to adding a quota/billing project (such as `agents-playground-XXXX`) to the generated ADC file:
     ```text
     Quota project "agents-playground-XXXX" was added to ADC which can be used by Google client libraries for quota and billing.
     ```
   - This is perfectly fine and safe, as the Vertex SDK inherits the quota project for billing checks while targeting the models under the active project.
   - Since `/data/openclaw` is a persistent volume, the generated ADC file at `/data/openclaw/.config/gcloud/application_default_credentials.json` completely survives container updates, image rebuilds, and device restarts.

### Configuring Google Vertex AI Models in OpenClaw

If you have configured GCP Authentication (either via Service Account JSON or User Login) using the steps above, you can register and use Google Vertex AI models inside OpenClaw.

To register and use Google's keyless Vertex models:

1. Open the Control UI or edit `/data/openclaw/versions/<version>/openclaw-home/.openclaw/openclaw.json` (or use `openclaw configure`).
2. Add the models under the `models.providers.google-vertex.models` list in your `openclaw.json`. Both `"id"` and `"name"` are required, and `"api": "google-vertex"` is **mandatory** to ensure OpenClaw uses the native Google Vertex transport protocol instead of falling back to OpenAI compatibility endpoints:
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
3. Set your active default model and fallbacks to use the Vertex models (prefixed with `google-vertex/`):
   ```json
   {
     "agents": {
       "defaults": {
         "model": "google-vertex/gemini-3.5-flash",
         "fallback": [
           "google-vertex/gemini-3.1-pro-preview",
           "google-vertex/gemini-3.1-flash-lite"
         ]
       }
     }
   }
   ```
4. Define a keyless authentication profile mapping for the `google-vertex` provider so OpenClaw knows there is an active profile:
   - In `openclaw.json`, ensure `"google-vertex:default"` is declared under `"auth"."profiles"`:
     ```json
     {
       "auth": {
         "profiles": {
           "google-vertex:default": {
             "provider": "google-vertex",
             "mode": "api_key"
           }
         }
       }
     }
     ```
   - In your agent's `auth-profiles.json` (located at `/data/openclaw/versions/<version>/openclaw-home/.openclaw/agents/main/agent/auth-profiles.json`), map this profile to use keyless Vertex credentials by passing `"gcp-vertex-credentials"` as the key:
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
     Using `"gcp-vertex-credentials"` signals to the OpenClaw Vertex plugin that it should bypass API key checks and inherit your GCP SDK environment/credentials directly!
5. Restart the gateway to apply the configuration.

> [!IMPORTANT]
> **Regional Location Warning (Vertex AI 3.x series)**:
> The Gemini 3.x models on Vertex AI (such as `gemini-3.5-flash`, `gemini-3.1-pro-preview`, and `gemini-3.1-flash-lite`) are currently only available on the **`global`** location/endpoint. Calling regional endpoints like `us-central1` or `europe-west3` for these models will return a `404 NOT_FOUND` error.
> 
> OpenClaw automatically defaults `GOOGLE_CLOUD_LOCATION` to `global` via its `docker-compose.yml` to prevent this. If you override `GOOGLE_CLOUD_LOCATION` in your Balena Device Variables, make sure to set it to `global` to use Gemini 3.x models.

## Automated Daily Backups

OpenClaw features a built-in automated daily backup daemon that safely snapshots your databases, configurations, memories, and plugins to a cloud provider. To preserve your Raspberry Pi's microSD card lifespan, the entire snapshot and compression process occurs safely in RAM (`tmpfs`), writing zero bytes to the physical disk before uploading.

### Configuring Box Backups

1. Create a **Custom App** in the [Box Developer Console](https://app.box.com/developers/console) and select **User Authentication (OAuth 2.0)**.
2. In the App Configuration, add the Redirect URI `http://127.0.0.1:53682/` and ensure the **"Write all files and folders"** scope is checked.
3. In the Balena dashboard, add the following device variables:
   - `BOX_CLIENT_ID`: Your Box App Client ID
   - `BOX_CLIENT_SECRET`: Your Box App Client Secret
4. Generate your offline `rclone` token by running this on your local Mac/PC:
   ```bash
   rclone authorize "box" "<your_client_id>" "<your_client_secret>"
   ```
5. SSH into the `openclaw` container and paste the generated JSON token block into the `[box]` section of `/data/openclaw/rclone.conf`:
   ```ini
   [box]
   type = box
   client_id = <your_client_id>
   client_secret = <your_client_secret>
   token = {"access_token":"...","token_type":"bearer","refresh_token":"...","expiry":"..."}
   ```

The daemon runs in the background and will execute every 24 hours. You can customize the remote name by setting `OPENCLAW_BACKUP_REMOTE` (default: `box`) and the destination folder with `OPENCLAW_BACKUP_DIR` (default: `openclaw-backups`).

## Manual Backups

`rclone` is installed in the `openclaw` container. It supports Dropbox, Google Drive, Box, S3, WebDAV, SFTP, and many other remotes.

```bash
rclone config
rclone sync /data/openclaw remote:backup
```

Or back up only the active OpenClaw home, which includes config, memories, skills, plugins, and agent data:

```bash
ACTIVE_VERSION="$(cat /data/openclaw/.current-version)"
rclone sync "/data/openclaw/versions/${ACTIVE_VERSION}/openclaw-home/.openclaw" remote:openclaw-home
```

## Local Development

```bash
docker compose up --build
```

Then open `https://localhost` and accept the self-signed certificate.

## License

MIT
