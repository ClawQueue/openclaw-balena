# OpenClaw on Balena

Run [OpenClaw](https://github.com/openclaw/openclaw) on a Raspberry Pi 4/5 as a self-hosted AI agent gateway. Deploy and manage via [balenaCloud](https://balena.io) with OTA updates, version snapshots with rollback, and automatic HTTPS.

---

## Architecture

Two containers:

| Container | Purpose |
|-----------|---------|
| `proxy` | HAProxy reverse proxy with self-signed TLS on ports 80/443. Handles LAN HTTPS, balena public URL tunnel, and header forwarding. |
| `openclaw` | OpenClaw gateway on port 8080 (Node.js). Config rendered from template at boot, with per-version snapshots for safe upgrades. |

---

## Setup

### 1. Deploy

Push to your fleet:

```bash
balena push <username>/<fleet-name>
```

Or use the balenaCloud deploy button.

### 2. Configure

Set these **Device Variables** in the balenaCloud dashboard:

#### Required

| Variable | Purpose |
|----------|---------|
| `DEFAULT_MODEL_REF` | Model to use, e.g. `openai/gpt-5.5`, `foundry/gpt-4o`, `google/gemini-2.5-pro` |

#### API Keys

Set at least one provider's key:

| Variable | Provider |
|----------|----------|
| `OPENAI_API_KEY` | OpenAI |
| `GOOGLE_API_KEY` | Google Gemini |
| `OPENROUTER_API_KEY` | OpenRouter |
| `FOUNDRY_API_KEY` + `FOUNDRY_ENDPOINT` | Microsoft Foundry (Azure OpenAI) |

All API keys are injected into `openclaw.json` and also exported to the runtime environment.

#### Microsoft Foundry setup

Foundry (Azure OpenAI) uses a custom endpoint — you need **both** variables:

1. `FOUNDRY_ENDPOINT` — your Azure OpenAI endpoint URL, e.g. `https://my-resource.openai.azure.com/openai/v1/`
2. `FOUNDRY_API_KEY` — your Azure OpenAI API key
3. Set `DEFAULT_MODEL_REF` to `foundry/gpt-4o` (or your deployed model name)

You can add other providers or custom endpoints by editing `gateway/config/openclaw.json5.template`.

### 3. Open the UI

- **LAN:** `https://<device-ip>` (accept self-signed cert)
- **Balena tunnel:** `https://<device-uuid>.balena-devices.com/`

The auth token is auto-generated on first boot (check device logs) or set via `OPENCLAW_GATEWAY_TOKEN`.

---

## Configuration

### How config works

The [config template](gateway/config/openclaw.json5.template) is rendered at boot via `envsubst` — all `${VAR}` placeholders are filled from balena device variables. This template is the **single source of truth** for your provider configuration.

- **First boot:** Renders from template → `openclaw.json`
- **Subsequent boots:** Uses existing `openclaw.json` (survives updates)
- **Re-render:** Set `OPENCLAW_RECONFIGURE=true` to backup the existing config and re-render from the updated template

### Provider config

Providers are defined explicitly in the template:

```json5
providers: [
  { id: "openai", provider: "openai", apiKey: "${OPENAI_API_KEY:-}" },
  { id: "google", provider: "google", apiKey: "${GOOGLE_API_KEY:-}" },
  { id: "openrouter", provider: "openrouter", apiKey: "${OPENROUTER_API_KEY:-}" },
  { id: "foundry", provider: "openai", apiKey: "${FOUNDRY_API_KEY:-}", baseURL: "${FOUNDRY_ENDPOINT:-}" },
],
defaultModel: "${DEFAULT_MODEL_REF:-openai/gpt-5.5}",
```

Add or modify providers by editing `gateway/config/openclaw.json5.template`, then deploy with `OPENCLAW_RECONFIGURE=true`.

### Configuring OpenClaw itself

Environment variables set in balenaCloud are exported to `~/.openclaw/.env` at boot. The template references them directly. Common config variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENCLAW_GATEWAY_PORT` | `8080` | Internal gateway listen port |
| `OPENCLAW_GATEWAY_TOKEN` | auto-generated | Auth token for control UI |
| `DEFAULT_MODEL_REF` | `openai/gpt-5.5` | Default AI model |

---

## Updating

### Update OpenClaw version

Set `OPENCLAW_VERSION` to a specific release (e.g. `2026.5.20`) and restart. The container downloads and activates it, cloning config/skills/plugins from the previous version.

Leave `OPENCLAW_VERSION` unset to use the version baked into the Docker image.

### Version snapshots & rollback

Each version is a **self-contained snapshot** under `/data/openclaw/versions/{version}/` containing the binary, config, skills, and plugins.

- **Upgrade:** Previous snapshot is cloned, new binary installed
- **Rollback:** Change `OPENCLAW_VERSION` back — the old snapshot activates as-is
- **Auto-prune:** Old snapshots auto-deleted. Set `OPENCLAW_KEEP_VERSIONS` (default: 3)

### Push config changes

1. Edit the template or haproxy config
2. Run `balena push <fleet>`
3. For config template changes: set `OPENCLAW_RECONFIGURE=true`, reboot, then remove it (optional — only needed when the template changes)

---

## Runtime Variables

| Variable | Purpose |
|----------|---------|
| `OPENCLAW_VERSION` | Install specific OpenClaw release |
| `OPENCLAW_RECONFIGURE` | Force re-render config from template on next boot |
| `OPENCLAW_AUTO_DOCTOR` | Run `openclaw doctor --fix` before starting |
| `OPENCLAW_GATEWAY_STOP` | Skip startup; keep container alive for debugging |
| `OPENCLAW_GATEWAY_TOKEN` | Custom auth token |
| `OPENCLAW_SKILLS` | Comma-separated ClawHub skill slugs |
| `OPENCLAW_PLUGINS` | Comma-separated npm plugin packages |
| `OPENCLAW_KEEP_VERSIONS` | Number of version snapshots to keep (default: 3) |
| `HAPROXY_CERT_CN` | CN for self-signed cert (default: `openclaw.local`) |

---

## Storage

| Volume | Mount | Contents |
|--------|-------|----------|
| `openclaw_data` | `/data` | Version snapshots, config, gateway token |
| `openclaw_home` | `/root` | Home directory (skills, plugins, sessions) |
| `proxy_certs` | `/etc/haproxy/certs` | Self-signed TLS certificate |

```
/data/openclaw/
├── versions/2026.5.20/
│   ├── npm-global/         # openclaw binary
│   ├── openclaw.json       # rendered config
│   └── openclaw-home/      # .openclaw/ data
├── gateway.token
└── .current-version
```

---

## Security

- HTTPS via HAProxy with self-signed TLS (both LAN and balena tunnel)
- Balena public URL traffic served directly on port 80 (Balena terminates TLS upstream)
- API keys stored in balenaCloud Device Variables, never in git
- Origin and Host headers preserved through the proxy for correct redirect behavior

---

## Local Development

```bash
export OPENAI_API_KEY=sk-...
export DEFAULT_MODEL_REF=openai/gpt-5.5
docker compose up --build
```

Then open `https://localhost` (accept the self-signed cert).

---

## License

MIT

---

## Updating OpenClaw

You can update OpenClaw without rebuilding the image. Set the `OPENCLAW_VERSION` device variable to a specific release (e.g. `2026.2.19`) and restart the service. The container will install the requested version at boot and keep it in persistent storage.

Leave `OPENCLAW_VERSION` unset to keep the version that was baked in at the last image build.

**Finding the latest version:**

Check [OpenClaw releases on GitHub](https://github.com/openclaw/openclaw/releases) for the latest stable version, or check your device logs to see which version is currently running (printed on startup).

### Versioned Snapshots & Rollback

Each version is a **fully self-contained snapshot** under `/data/openclaw/versions/{version}/`, including config, skills, plugins, memory, and the openclaw binary. This means rolling back to a previous version restores everything exactly as it was — no risk of config incompatibility.

**When upgrading to a new version:**
1. Config, skills, plugins, and memory are cloned from the previous version's snapshot
2. A fresh openclaw binary is installed into the new snapshot
3. If the upgrade fails, the previous version is used automatically

**When rolling back:**
1. Change `OPENCLAW_VERSION` back to the desired version (e.g., `2026.2.12`)
2. The previous snapshot is activated as-is — config, skills, and memory are exactly as they were

**Auto-pruning:**
Old version snapshots are automatically pruned to save disk space. Set `OPENCLAW_KEEP_VERSIONS` to control how many are kept (default: 3). The current version is never pruned.

```bash
# List installed version snapshots
ls /data/openclaw/versions/

# Manually remove a specific old version
rm -rf /data/openclaw/versions/2026.2.10
```

### Persistent Storage

Two volumes persist across container updates and restarts:

| Volume | Mount | Contents |
|--------|-------|----------|
| `openclaw_data` | `/data` | OpenClaw versions, config, state, and npm-installed binaries |
| `openclaw_home` | `/root` | User home including skills, plugins, sessions, and application configs |
| `proxy_certs` | `/etc/haproxy/certs` | Self-signed TLS certificate (persists across restarts) |

**Storage structure:**
```
/data/openclaw/
├── versions/
│   ├── 2026.2.19/
│   │   ├── npm-global/          # openclaw binary + node_modules
│   │   ├── openclaw.json        # version-specific config
│   │   └── openclaw-home/       # .openclaw/ snapshot (skills, plugins, memory)
│   └── 2026.2.18/
│       └── ...
├── gateway.token                 # shared auth token
└── .current-version              # tracks active version
```

`~/.openclaw` is symlinked to the active version's `openclaw-home/` directory, so all openclaw commands operate within the current snapshot.

All data is preserved when updating OpenClaw version or restarting the container.

---

## Skills & Plugins

OpenClaw supports two extension mechanisms. Both persist across reboots in the device volume.

### Skills

[Skills](https://docs.openclaw.ai/tools/skills) are knowledge packages (`SKILL.md` files) that teach the AI how to use tools and services. Install them at boot by setting:

```
OPENCLAW_SKILLS=home-assistant,web-search
```

### Plugins

[Plugins](https://docs.openclaw.ai/plugin) are code modules that add new integrations (messaging channels, tools, AI providers). Install them at boot by setting:

```
OPENCLAW_PLUGINS=@openclaw/voice-call
```

You can also install skills and plugins through the OpenClaw Gateway UI at any time — they persist in the device volume and don't need to be listed in the env vars.

---

## Local development

```bash
export GOOGLE_API_KEY=AIza...   # or any other provider key
docker compose up --build
```

Then open https://localhost (accept the self-signed certificate warning)

---

## Security

- All traffic is served over HTTPS via an HAProxy reverse proxy with a self-signed certificate. HTTP on port 80 redirects to HTTPS automatically
- To replace the self-signed certificate with your own, place a PEM file (key + cert concatenated) at `/etc/haproxy/certs/self-signed.pem` on the `proxy_certs` volume
- Set `OPENCLAW_GATEWAY_TOKEN` explicitly rather than relying on auto-generation
- Keep API keys in balenaCloud Device Variables, not in code
- Audit skills before granting them elevated privileges
- Consider running the device on an isolated network segment

---

## License

MIT
