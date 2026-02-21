#!/bin/bash
#
# Airflow MCP Setup Script
# ========================
# Creates personal MCP configs from committed example templates.
# Each team member runs this script - personal configs are gitignored.
#
# SUPPORTED TOOLS:
#   - Claude Code: Project-level .mcp.json (handled by this script)
#   - VSCode Copilot: Project-level .vscode/mcp.json (handled by this script)
#   - AmpCode: Global VSCode settings (handled by this script)
#
# AMPCODE NOTE:
#   Amp VSCode Extension reads from global VSCode settings, not .amp/settings.json.
#   Unlike other MCP clients, AmpCode ignores "disabled": true and still tries to connect.
#   So we must fully remove the config when disabling (and re-add when enabling).
#   See: https://ampcode.com/manual#configuration
#
# HOW IT WORKS:
#   - Copy .env.example to .env and fill in credentials (gitignored)
#   - Example files (.example.json) are committed to git as templates
#   - This script sources .env and copies templates to active configs,
#     replacing $PROJECT_DIR and credentials with actual values
#   - Personal configs are gitignored
#
# FIRST TIME SETUP:
#   cp .env.example .env   # fill in AIRFLOW_PASSWORD
#   ./setup-mcp.sh all
#
# WHEN NOT ON VPN:
#   ./setup-mcp.sh disable     → Avoid connection timeouts on tool startup
#   ./setup-mcp.sh enable      → Re-enable when back on VPN
#
# CROSS-REPO SUPPORT:
#   Setup/disable/enable also manage configs in external repos (default: ../airflow).
#   Override with .mcp-repos file (one path per line, relative to this script).
#
# Usage:
#   ./setup-mcp.sh claude   # Setup Claude Code
#   ./setup-mcp.sh vscode   # Setup VSCode Copilot
#   ./setup-mcp.sh ampcode  # Setup AmpCode (adds to VSCode settings)
#   ./setup-mcp.sh all      # Setup all three tools
#   ./setup-mcp.sh disable  # Disable all MCP configs
#   ./setup-mcp.sh enable   # Re-enable all MCP configs
#   ./setup-mcp.sh status   # Show current config status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# LOAD CREDENTIALS FROM .env
# ============================================================================

ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
else
    # Allow status/disable/enable without credentials, but warn for setup commands
    _env_missing=true
fi

# ============================================================================
# CONFIG FILE PATHS
# ============================================================================

CLAUDE_EXAMPLE="$SCRIPT_DIR/.mcp.example.json"
CLAUDE_CONFIG="$SCRIPT_DIR/.mcp.json"

VSCODE_EXAMPLE="$SCRIPT_DIR/.vscode/mcp.example.json"
VSCODE_CONFIG="$SCRIPT_DIR/.vscode/mcp.json"

# AmpCode uses global VSCode settings
AMPCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"

# ============================================================================
# EXTERNAL REPOS (cross-repo MCP config management)
# ============================================================================
# By default, setup/disable/enable also manage MCP configs in ../airflow.
# Override by creating .mcp-repos with one repo path per line.

MCP_REPOS_FILE="$SCRIPT_DIR/.mcp-repos"

get_external_repos() {
    if [ -f "$MCP_REPOS_FILE" ]; then
        local repos=()
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            line="$(echo "$line" | sed 's/#.*//' | xargs)"
            [ -z "$line" ] && continue
            repos+=("$line")
        done < "$MCP_REPOS_FILE"
        echo "${repos[@]}"
    else
        echo "../airflow"
    fi
}

resolve_repo_path() {
    local repo="$1"
    local resolved

    # Resolve relative paths from SCRIPT_DIR
    if [[ "$repo" != /* ]]; then
        resolved="$(cd "$SCRIPT_DIR" && cd "$repo" 2>/dev/null && pwd)" || true
    else
        resolved="$repo"
    fi

    # Return empty if directory doesn't exist
    if [ -n "$resolved" ] && [ -d "$resolved" ]; then
        echo "$resolved"
    fi
}

repo_basename() {
    basename "$(resolve_repo_path "$1" || echo "$1")"
}

# ============================================================================
# OUTPUT HELPERS
# ============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

check_env() {
    if [ "${_env_missing:-false}" = "true" ]; then
        log_error ".env not found — copy .env.example to .env and fill in credentials"
        echo "  cp .env.example .env"
        exit 1
    fi
    if [ -z "${AIRFLOW_USERNAME:-}" ] || [ -z "${AIRFLOW_PASSWORD:-}" ]; then
        log_error "AIRFLOW_USERNAME or AIRFLOW_PASSWORD not set in .env"
        exit 1
    fi
}

show_help() {
    echo ""
    echo -e "${BLUE}Airflow MCP Setup${NC}"
    echo ""
    echo "First time: cp .env.example .env  (fill in credentials)"
    echo ""
    echo "Setup commands:"
    echo "  claude   Setup Claude Code"
    echo "  vscode   Setup VSCode Copilot"
    echo "  ampcode  Setup AmpCode (modifies VSCode settings)"
    echo "  all      Setup all three tools"
    echo ""
    echo "Toggle commands:"
    echo "  disable  Disable all MCP configs (when not on VPN)"
    echo "  enable   Re-enable all MCP configs"
    echo "  status   Show current config status"
    echo ""
}

# ============================================================================
# AMPCODE HELPERS (VSCode Settings Manipulation)
# ============================================================================
# Uses Python to safely add/remove airflow-dev in VSCode settings.json.
# NOTE: AmpCode ignores "disabled": true, so we must fully remove the config.
# - ampcode_add: Adds airflow-dev config to amp.mcpServers
# - ampcode_remove: Removes airflow-dev config entirely (for disable)
# ============================================================================

ampcode_exists() {
    if [ -f "$AMPCODE_SETTINGS" ]; then
        grep -q '"airflow-dev"' "$AMPCODE_SETTINGS" 2>/dev/null
        return $?
    fi
    return 1
}

ampcode_add() {
    if ! [ -f "$AMPCODE_SETTINGS" ]; then
        log_error "VSCode settings not found: $AMPCODE_SETTINGS"
        return 1
    fi

    if ampcode_exists; then
        log_warn "AmpCode airflow-dev already exists"
        return 0
    fi

    local _username="${AIRFLOW_USERNAME:-}"
    local _password="${AIRFLOW_PASSWORD:-}"

    # Use Python to safely add the entry
    python3 << EOF
import re
import json
import sys

settings_path = "$AMPCODE_SETTINGS"
project_dir = "$SCRIPT_DIR"

# The airflow-dev config to add
airflow_config = {
    "command": "uv",
    "args": [
        "run",
        "--directory",
        project_dir,
        "mcp-server-apache-airflow"
    ],
    "env": {
        "AIRFLOW_HOST": "https://pidgey.ready-internal.net",
        "AIRFLOW_USERNAME": "$_username",
        "AIRFLOW_PASSWORD": "$_password",
        "AIRFLOW_VERIFY": "false",
        "READ_ONLY": "true"
    }
}

try:
    with open(settings_path, 'r') as f:
        content = f.read()

    # Find amp.mcpServers section
    pattern = r'("amp\.mcpServers"\s*:\s*\{)'
    match = re.search(pattern, content)

    if match:
        # Insert after the opening brace
        insert_pos = match.end()
        entry_json = json.dumps(airflow_config, indent=4)
        indented = '\n'.join('        ' + line if i > 0 else line
                            for i, line in enumerate(entry_json.split('\n')))
        new_entry = f'\n        "airflow-dev": {indented},'

        new_content = content[:insert_pos] + new_entry + content[insert_pos:]

        with open(settings_path, 'w') as f:
            f.write(new_content)
        print("added")
    else:
        print("no_section")
        sys.exit(1)

except Exception as e:
    print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

    result=$?
    if [ $result -eq 0 ]; then
        log_info "Added airflow-dev to AmpCode (VSCode settings)"
        return 0
    else
        log_error "Failed to add airflow-dev to VSCode settings"
        echo "  You may need to add it manually. See GETTING-STARTED.md"
        return 1
    fi
}

ampcode_remove() {
    if ! [ -f "$AMPCODE_SETTINGS" ]; then
        return 0
    fi

    if ! ampcode_exists; then
        return 0  # Already removed
    fi

    # Use Python to remove the entire airflow-dev entry
    python3 << EOF
import re
import sys

settings_path = "$AMPCODE_SETTINGS"

try:
    with open(settings_path, 'r') as f:
        content = f.read()

    # Remove "airflow-dev": { ... }, entry
    # Use a balanced brace matching approach for nested objects

    # Find start of airflow-dev
    start_pattern = r'\s*"airflow-dev"\s*:\s*\{'
    match = re.search(start_pattern, content)

    if match:
        start = match.start()
        # Find matching closing brace by counting braces
        brace_count = 0
        i = match.end() - 1  # Start at the opening brace
        while i < len(content):
            if content[i] == '{':
                brace_count += 1
            elif content[i] == '}':
                brace_count -= 1
                if brace_count == 0:
                    end = i + 1
                    break
            i += 1

        # Include trailing comma and whitespace if present
        remaining = content[end:]
        comma_match = re.match(r'\s*,', remaining)
        if comma_match:
            end += comma_match.end()

        new_content = content[:start] + content[end:]

        # Clean up any resulting double commas or leading commas
        new_content = re.sub(r',(\s*[,}])', r'\1', new_content)
        new_content = re.sub(r'\{\s*,', '{', new_content)

        with open(settings_path, 'w') as f:
            f.write(new_content)
        print("removed")
    else:
        print("not_found")

except Exception as e:
    print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

    result=$?
    if [ $result -eq 0 ]; then
        log_info "Removed airflow-dev from AmpCode (VSCode settings)"
        return 0
    fi
    return 1
}

# ampcode_enable is just an alias for ampcode_add
ampcode_enable() {
    ampcode_add
    return $?
}

# ampcode_disable is just an alias for ampcode_remove
ampcode_disable() {
    ampcode_remove
    return $?
}

show_status() {
    echo ""
    echo -e "${BLUE}Config Status — $(basename "$SCRIPT_DIR")${NC}"
    echo ""

    # Claude Code
    if [ -f "$CLAUDE_CONFIG" ]; then
        echo -e "  Claude Code  (.mcp.json)             ${GREEN}enabled${NC}"
    elif [ -f "${CLAUDE_CONFIG}.disabled" ]; then
        echo -e "  Claude Code  (.mcp.json)             ${RED}disabled${NC}"
    else
        echo -e "  Claude Code  (.mcp.json)             ${YELLOW}not setup${NC}"
    fi

    # VSCode Copilot
    if [ -f "$VSCODE_CONFIG" ]; then
        echo -e "  VSCode       (.vscode/mcp.json)      ${GREEN}enabled${NC}"
    elif [ -f "${VSCODE_CONFIG}.disabled" ]; then
        echo -e "  VSCode       (.vscode/mcp.json)      ${RED}disabled${NC}"
    else
        echo -e "  VSCode       (.vscode/mcp.json)      ${YELLOW}not setup${NC}"
    fi

    # AmpCode (exists = enabled, not exists = disabled/not setup)
    if ampcode_exists; then
        echo -e "  AmpCode      (VSCode settings.json)  ${GREEN}enabled${NC}"
    else
        echo -e "  AmpCode      (VSCode settings.json)  ${RED}disabled${NC}"
    fi

    # .env credentials
    echo ""
    if [ -f "$ENV_FILE" ] && [ -n "${AIRFLOW_USERNAME:-}" ]; then
        echo -e "  Credentials  (.env)                  ${GREEN}loaded${NC}"
    else
        echo -e "  Credentials  (.env)                  ${YELLOW}missing — cp .env.example .env${NC}"
    fi

    # External repos
    for repo in $(get_external_repos); do
        local repo_path
        repo_path="$(resolve_repo_path "$repo")"
        if [ -z "$repo_path" ]; then
            echo ""
            echo -e "${BLUE}Config Status — $repo${NC}"
            echo -e "  ${YELLOW}repo not found${NC}"
            continue
        fi

        local name
        name="$(basename "$repo_path")"
        echo ""
        echo -e "${BLUE}Config Status — $name${NC}"
        echo ""

        local ext_claude="$repo_path/.mcp.json"
        if [ -f "$ext_claude" ]; then
            echo -e "  Claude Code  (.mcp.json)             ${GREEN}enabled${NC}"
        elif [ -f "${ext_claude}.disabled" ]; then
            echo -e "  Claude Code  (.mcp.json)             ${RED}disabled${NC}"
        else
            echo -e "  Claude Code  (.mcp.json)             ${YELLOW}not setup${NC}"
        fi

        local ext_vscode="$repo_path/.vscode/mcp.json"
        if [ -f "$ext_vscode" ]; then
            echo -e "  VSCode       (.vscode/mcp.json)      ${GREEN}enabled${NC}"
        elif [ -f "${ext_vscode}.disabled" ]; then
            echo -e "  VSCode       (.vscode/mcp.json)      ${RED}disabled${NC}"
        else
            echo -e "  VSCode       (.vscode/mcp.json)      ${YELLOW}not setup${NC}"
        fi
    done

    echo ""
}

# ============================================================================
# CREATE CONFIG FROM EXAMPLE TEMPLATE
# ============================================================================

create_config() {
    local example="$1"
    local config="$2"
    local name="$3"
    local project_dir="${4:-$SCRIPT_DIR}"  # Default to SCRIPT_DIR for local configs

    if [ ! -f "$example" ]; then
        log_warn "Example not found: $example"
        return 1
    fi

    mkdir -p "$(dirname "$config")"

    # Check for disabled config and restore it
    if [ -f "${config}.disabled" ]; then
        mv "${config}.disabled" "$config"
        log_info "Restored $name (was disabled)"
        return 0
    fi

    if [ -f "$config" ]; then
        log_warn "$name already exists, skipping"
        return 0
    fi

    # Replace $PROJECT_DIR and credentials — always points to SCRIPT_DIR so config is shared
    sed -e "s|\\\$PROJECT_DIR|$SCRIPT_DIR|g" \
        -e "s|\\\$AIRFLOW_USERNAME|${AIRFLOW_USERNAME}|g" \
        -e "s|\\\$AIRFLOW_PASSWORD|${AIRFLOW_PASSWORD}|g" \
        "$example" > "$config"
    log_info "Created $name"
}

setup_external_repos_claude() {
    for repo in $(get_external_repos); do
        local repo_path
        repo_path="$(resolve_repo_path "$repo")"
        if [ -z "$repo_path" ]; then
            log_warn "External repo not found: $repo (skipping)"
            continue
        fi
        local name
        name="$(basename "$repo_path")"
        create_config "$CLAUDE_EXAMPLE" "$repo_path/.mcp.json" "$name — Claude Code (.mcp.json)"
    done
}

setup_external_repos_vscode() {
    for repo in $(get_external_repos); do
        local repo_path
        repo_path="$(resolve_repo_path "$repo")"
        if [ -z "$repo_path" ]; then
            log_warn "External repo not found: $repo (skipping)"
            continue
        fi
        local name
        name="$(basename "$repo_path")"
        create_config "$VSCODE_EXAMPLE" "$repo_path/.vscode/mcp.json" "$name — VSCode (.vscode/mcp.json)"
    done
}

# ============================================================================
# SETUP COMMANDS
# ============================================================================

setup_claude() {
    check_env
    echo ""
    echo -e "${BLUE}Setting up Claude Code...${NC}"
    echo ""
    create_config "$CLAUDE_EXAMPLE" "$CLAUDE_CONFIG" "Claude Code (.mcp.json)"
    setup_external_repos_claude
    echo ""
    echo "Next steps:"
    echo "  1. Restart Claude Code in this project"
    echo "  2. Test: ask Claude to list Airflow DAGs"
    echo ""
}

setup_vscode() {
    check_env
    echo ""
    echo -e "${BLUE}Setting up VSCode Copilot...${NC}"
    echo ""
    create_config "$VSCODE_EXAMPLE" "$VSCODE_CONFIG" "VSCode (.vscode/mcp.json)"
    setup_external_repos_vscode
    echo ""
    echo "Restart VSCode to load MCP."
    echo ""
}

setup_ampcode() {
    check_env
    echo ""
    echo -e "${BLUE}Setting up AmpCode...${NC}"
    echo ""
    ampcode_add
    echo ""
    echo "Restart VSCode/AmpCode to load MCP."
    echo ""
}

setup_all() {
    check_env
    echo ""
    echo -e "${BLUE}Setting up all tools...${NC}"
    echo ""
    create_config "$CLAUDE_EXAMPLE" "$CLAUDE_CONFIG" "Claude Code (.mcp.json)"
    create_config "$VSCODE_EXAMPLE" "$VSCODE_CONFIG" "VSCode (.vscode/mcp.json)"
    ampcode_add
    setup_external_repos_claude
    setup_external_repos_vscode
    echo ""
    echo "Restart Claude Code, VSCode, and AmpCode to load MCP."
    echo ""
}

# ============================================================================
# TOGGLE COMMANDS (DISABLE/ENABLE)
# ============================================================================

disable_all() {
    echo ""
    echo -e "${BLUE}Disabling MCP configs...${NC}"
    echo ""

    local disabled=0

    if [ -f "$CLAUDE_CONFIG" ]; then
        mv "$CLAUDE_CONFIG" "${CLAUDE_CONFIG}.disabled"
        log_info "Disabled Claude Code"
        disabled=$((disabled + 1))
    fi

    if [ -f "$VSCODE_CONFIG" ]; then
        mv "$VSCODE_CONFIG" "${VSCODE_CONFIG}.disabled"
        log_info "Disabled VSCode Copilot"
        disabled=$((disabled + 1))
    fi

    if ampcode_exists; then
        ampcode_disable
        disabled=$((disabled + 1))
    fi

    # Disable in external repos
    for repo in $(get_external_repos); do
        local repo_path
        repo_path="$(resolve_repo_path "$repo")"
        [ -z "$repo_path" ] && continue
        local name
        name="$(basename "$repo_path")"

        local ext_claude="$repo_path/.mcp.json"
        if [ -f "$ext_claude" ]; then
            mv "$ext_claude" "${ext_claude}.disabled"
            log_info "Disabled $name — Claude Code"
            disabled=$((disabled + 1))
        fi

        local ext_vscode="$repo_path/.vscode/mcp.json"
        if [ -f "$ext_vscode" ]; then
            mv "$ext_vscode" "${ext_vscode}.disabled"
            log_info "Disabled $name — VSCode Copilot"
            disabled=$((disabled + 1))
        fi
    done

    if [ $disabled -eq 0 ]; then
        log_warn "No configs to disable"
    else
        echo ""
        echo "Restart your tools."
        echo "Run './setup-mcp.sh enable' to re-enable."
    fi
    echo ""
}

enable_all() {
    echo ""
    echo -e "${BLUE}Re-enabling MCP configs...${NC}"
    echo ""

    local enabled=0

    if [ -f "${CLAUDE_CONFIG}.disabled" ]; then
        mv "${CLAUDE_CONFIG}.disabled" "$CLAUDE_CONFIG"
        log_info "Enabled Claude Code"
        enabled=$((enabled + 1))
    fi

    if [ -f "${VSCODE_CONFIG}.disabled" ]; then
        mv "${VSCODE_CONFIG}.disabled" "$VSCODE_CONFIG"
        log_info "Enabled VSCode Copilot"
        enabled=$((enabled + 1))
    fi

    # Add AmpCode if not exists (exists = already enabled)
    if ! ampcode_exists; then
        ampcode_add
        enabled=$((enabled + 1))
    fi

    # Enable in external repos
    for repo in $(get_external_repos); do
        local repo_path
        repo_path="$(resolve_repo_path "$repo")"
        [ -z "$repo_path" ] && continue
        local name
        name="$(basename "$repo_path")"

        local ext_claude="$repo_path/.mcp.json"
        if [ -f "${ext_claude}.disabled" ]; then
            mv "${ext_claude}.disabled" "$ext_claude"
            log_info "Enabled $name — Claude Code"
            enabled=$((enabled + 1))
        fi

        local ext_vscode="$repo_path/.vscode/mcp.json"
        if [ -f "${ext_vscode}.disabled" ]; then
            mv "${ext_vscode}.disabled" "$ext_vscode"
            log_info "Enabled $name — VSCode Copilot"
            enabled=$((enabled + 1))
        fi
    done

    if [ $enabled -eq 0 ]; then
        log_warn "No disabled configs found"
        echo "Run './setup-mcp.sh all' to create configs."
    else
        echo ""
        echo "Restart your tools to load MCP."
    fi
    echo ""
}

# ============================================================================
# MAIN - PARSE COMMAND
# ============================================================================

case "${1:-}" in
    claude)
        setup_claude
        ;;
    vscode)
        setup_vscode
        ;;
    ampcode|amp)
        setup_ampcode
        ;;
    rest)
        # Legacy alias
        setup_vscode
        setup_ampcode
        ;;
    all)
        setup_all
        show_status
        ;;
    disable|off)
        disable_all
        show_status
        ;;
    enable|on)
        enable_all
        show_status
        ;;
    status)
        show_status
        ;;
    *)
        show_help
        show_status
        ;;
esac
