# Getting Started: Airflow MCP Server

Quick setup and example prompts for using the Airflow MCP with AI coding assistants.

---

## Setup

### 1. Install

```bash
git clone git@github.com:ready/mcp-server-apache-airflow.git
cd mcp-server-apache-airflow
cp .env.example .env   # then fill in AIRFLOW_PASSWORD (ask data team lead)
uv sync
```

### 2. Configure all tools at once

```bash
./setup-mcp.sh all
```

Restart Claude Code, VSCode, and AmpCode → test: *"List all Airflow DAGs"*

Or configure tools individually:

```bash
./setup-mcp.sh claude   # Claude Code only
./setup-mcp.sh vscode   # VSCode Copilot only
./setup-mcp.sh ampcode  # AmpCode only
```

> **Note:** Amp VSCode Extension reads from global VSCode settings, not project files.
> The script adds `airflow-dev` to `~/Library/Application Support/Code/User/settings.json`.
> Unlike Claude Code/VSCode, AmpCode ignores `"disabled": true` — so we must fully remove
> the config when disabling (and re-add when enabling).
> See [ampcode.com/manual](https://ampcode.com/manual#configuration) for details.

### 3. Disable When Not on VPN

```bash
./setup-mcp.sh disable   # Disables all MCP configs (avoids connection timeouts)
./setup-mcp.sh enable    # Re-enable when back on VPN
./setup-mcp.sh status    # Check current status
```

**How disable/enable works:**

| Tool           | Disable                                    | Enable         |
| -------------- | ------------------------------------------ | -------------- |
| Claude Code    | Renames `.mcp.json` → `.mcp.json.disabled` | Restores file  |
| VSCode Copilot | Renames `.vscode/mcp.json` → `.disabled`   | Restores file  |
| AmpCode        | Removes `airflow-dev` from VSCode settings | Re-adds config |

These actions apply to both the MCP server repo and external repos (see below).

### 4. Cross-Repo Support

`setup`, `disable`, `enable`, and `status` automatically manage MCP configs in external repos — by default `../airflow`. This means when you run Claude Code or VSCode in the airflow repo, the Airflow MCP server is available there too.

The generated configs in external repos point `--directory` back to this MCP server repo.

**Custom repo list:** Create a `.mcp-repos` file (gitignored) to override the default:

```bash
# .mcp-repos — one repo path per line (relative to this script)
../airflow
../another-repo
```

If `.mcp-repos` doesn't exist, the default is `../airflow`.

---

## Tips

**Daily workflow:** Once initial setup is done, just use:
```bash
./setup-mcp.sh enable    # Reconnects all agents when back on VPN
./setup-mcp.sh disable   # Disconnects all when leaving VPN
```

**Credentials stored in:** `.env` (gitignored). If you need to update the password, edit `.env` then re-run `./setup-mcp.sh all` (delete existing configs first if they already exist).

---

## Example Prompts

| Prompt                                               | What it does          |
| ---------------------------------------------------- | --------------------- |
| *"List all Airflow DAGs"*                            | Shows available DAGs  |
| *"Are there any failed DAG runs today?"*             | Checks for failures   |
| *"Why did `my_dag` fail yesterday? Show error logs"* | Investigates failures |

---

## Real Examples

See [examples/](examples/) for detailed MCP interactions:

| Example                                                        | Description                                   |
| -------------------------------------------------------------- | --------------------------------------------- |
| [Analyze DAG Run Configs](examples/analyze-dag-run-configs.md) | Extract config patterns from 120+ manual runs |

---

## Links

- [README](README.md) - Full documentation, troubleshooting, architecture
- [Airflow MCP Servers](AIRFLOW-MCP-SERVERS.md) - Alternative servers comparison, Airflow v3 migration
- [setup-mcp.sh](setup-mcp.sh) - Setup and toggle MCP configs
- [update-hosts.sh](update-hosts.sh) - VPN DNS fix
