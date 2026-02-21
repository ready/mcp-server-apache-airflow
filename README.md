# Apache Airflow MCP Server

MCP server for Apache Airflow, configured for the Ready data team with basic auth and read-only access.

| Repository   | URL                                                       |
| ------------ | --------------------------------------------------------- |
| **Upstream** | https://github.com/yangkyeongmo/mcp-server-apache-airflow |
| **Ready**    | https://github.com/ready/mcp-server-apache-airflow        |

> **New to this repo?** See [Getting Started](GETTING-STARTED.md) for quick setup and example prompts.

---

## Quick Start

```bash
git clone git@github.com:ready/mcp-server-apache-airflow.git
cd mcp-server-apache-airflow
cp .env.example .env   # fill in AIRFLOW_PASSWORD (ask data team lead)
uv sync
./setup-mcp.sh all     # configures Claude Code, VSCode Copilot, and AmpCode
```

Restart your tools and test: *"List all Airflow DAGs"*

📖 **See [Getting Started](GETTING-STARTED.md)** for detailed setup, disable/enable workflow, and example prompts.

---

## Authentication

The server uses **basic auth** with a shared read-only Airflow account. Credentials are stored in `.env` (gitignored) and injected into generated MCP configs by `setup-mcp.sh`.

Auth priority in `create_api_client()`:
1. **JWT Token** — if `AIRFLOW_JWT_TOKEN` is set
2. **Basic Auth** — if `AIRFLOW_USERNAME` and `AIRFLOW_PASSWORD` are set
3. **Unauthenticated** — fallback (logs a warning)

---

## Environment Variables

| Variable              | Default                 | Description                                              |
| --------------------- | ----------------------- | -------------------------------------------------------- |
| `AIRFLOW_HOST`        | `http://localhost:8080` | Airflow base URL (required)                              |
| `AIRFLOW_USERNAME`    | —                       | Basic auth username                                      |
| `AIRFLOW_PASSWORD`    | —                       | Basic auth password                                      |
| `AIRFLOW_JWT_TOKEN`   | —                       | JWT bearer token (alternative to basic auth)             |
| `AIRFLOW_API_VERSION` | `v1`                    | REST API version (`v1` for Airflow 2.x)                  |
| `AIRFLOW_VERIFY`      | `true`                  | TLS verification (`true`, `false`, or path to CA bundle) |
| `READ_ONLY`           | `false`                 | Restrict to read-only API operations                     |

---

## Troubleshooting

| Error                               | Cause                               | Fix                                        |
| ----------------------------------- | ----------------------------------- | ------------------------------------------ |
| `401 Unauthorized`                  | Wrong credentials                   | Check `.env` username/password             |
| `ENOTFOUND` or DNS resolution fails | VPN DNS not propagating to all apps | Run `sudo ./update-hosts.sh` (see below)   |
| SSL certificate errors              | Self-signed or internal CA          | Set `AIRFLOW_VERIFY=false` in `.env`       |
| MCP server not loading              | Config not found                    | Run `./setup-mcp.sh all` and restart tools |

### VPN DNS Issues

Some apps may fail to resolve internal hostnames like `pidgey.ready-internal.net` even when connected to VPN.

**Fix:** Use [`update-hosts.sh`](update-hosts.sh) to write the resolved IP directly to `/etc/hosts`:

```bash
# One-time fix (requires sudo)
sudo ./update-hosts.sh

# Automate via cron (every 30 minutes)
sudo crontab -e
# Add: */30 * * * * /path/to/update-hosts.sh >> /var/log/hosts-update.log 2>&1
```

---

## Available Tools

The MCP server exposes Airflow API operations as tools. With `READ_ONLY=true` set, only read operations are available.

| Module          | Operations                                     |
| --------------- | ---------------------------------------------- |
| DAGs            | List, get details, pause/unpause               |
| DAG Runs        | List, get details, trigger, clear              |
| Task Instances  | List, get details, set state                   |
| Variables       | List, get, create, update, delete              |
| Connections     | List, get, create, update, delete              |
| Pools           | List, get, create, update, delete              |
| Datasets        | List, get, get events                          |
| Event Log       | List events                                    |
| Import Errors   | List                                           |
| Monitoring      | Health check                                   |
| Plugins         | List                                           |
| Providers       | List                                           |
| Config          | Get configuration                              |
| XCom            | List, get                                      |

---

## Setup Script

[`setup-mcp.sh`](setup-mcp.sh) manages MCP configs for Claude Code, VSCode Copilot, and AmpCode:

```bash
./setup-mcp.sh all      # Setup all three tools
./setup-mcp.sh disable  # Disable all (when not on VPN)
./setup-mcp.sh enable   # Re-enable all
./setup-mcp.sh status   # Show current status
```

Configs are generated from `.example.json` templates by substituting `$PROJECT_DIR` and credentials from `.env`. Generated configs are gitignored.

---

## Notes

- ⚠️ **Airflow 2.x EOL: April 2026** — This server targets Airflow 2.x (`/api/v1`). Migration to Airflow 3.0 (`/api/v2`) requires updates to API version and possibly JWT auth.
- 📖 See [Airflow MCP Servers](AIRFLOW-MCP-SERVERS.md) for alternative servers and v3 migration notes.
