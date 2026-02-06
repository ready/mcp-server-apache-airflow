#!/bin/bash
#
# Tests for setup-mcp.sh cross-repo functionality
# ================================================
# Uses a temp directory to simulate the MCP server repo and external repos.
# Does NOT touch real configs or the real ../airflow repo.
#
# Run: bash test/test_setup_mcp.sh
#

set -e

# ============================================================================
# TEST FRAMEWORK
# ============================================================================

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

assert_file_exists() {
    local file="$1"
    local msg="${2:-$file should exist}"
    if [ -f "$file" ]; then
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $msg (file not found: $file)"
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    local msg="${2:-$file should not exist}"
    if [ ! -f "$file" ]; then
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $msg (file exists: $file)"
        return 1
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-$file should contain '$pattern'}"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $msg"
        return 1
    fi
}

assert_output_contains() {
    local output="$1"
    local pattern="$2"
    local msg="${3:-output should contain '$pattern'}"
    if echo "$output" | grep -q "$pattern"; then
        return 0
    else
        echo -e "  ${RED}FAIL${NC}: $msg"
        return 1
    fi
}

run_test() {
    local name="$1"
    local func="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}TEST${NC}: $name"
    if $func; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# SETUP / TEARDOWN
# ============================================================================

ORIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=""
MCP_DIR=""

setup_sandbox() {
    TEST_ROOT="$(mktemp -d)"
    MCP_DIR="$TEST_ROOT/mcp-server-apache-airflow"

    # Create fake MCP server repo
    mkdir -p "$MCP_DIR/.vscode"

    # Copy the real script and example files
    cp "$ORIG_DIR/setup-mcp.sh" "$MCP_DIR/setup-mcp.sh"
    cp "$ORIG_DIR/.mcp.example.json" "$MCP_DIR/.mcp.example.json"
    cp "$ORIG_DIR/.vscode/mcp.example.json" "$MCP_DIR/.vscode/mcp.example.json"

    # Create fake external repo (simulating ../airflow)
    mkdir -p "$TEST_ROOT/airflow"
    mkdir -p "$TEST_ROOT/airflow/.vscode"

    # Override AMPCODE_SETTINGS so we don't touch real VSCode settings
    local fake_settings="$TEST_ROOT/vscode-settings.json"
    echo '{"amp.mcpServers": {}}' > "$fake_settings"

    # Patch the script to use our fake AMPCODE_SETTINGS
    sed -i '' "s|AMPCODE_SETTINGS=.*|AMPCODE_SETTINGS=\"$fake_settings\"|" "$MCP_DIR/setup-mcp.sh"
}

teardown_sandbox() {
    if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
        rm -rf "$TEST_ROOT"
    fi
    TEST_ROOT=""
    MCP_DIR=""
}

# Helper: run setup-mcp.sh in the sandbox
run_setup() {
    bash "$MCP_DIR/setup-mcp.sh" "$@" 2>&1
}

# ============================================================================
# TESTS: get_external_repos / resolve_repo_path
# ============================================================================

test_default_external_repo() {
    setup_sandbox

    # Without .mcp-repos, default should be ../airflow
    local output
    output="$(run_setup claude)"

    # The script should have created .mcp.json in the airflow dir
    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "claude setup should create .mcp.json in ../airflow" &&
    assert_file_exists "$MCP_DIR/.mcp.json" "claude setup should create .mcp.json in mcp dir"

    teardown_sandbox
}

test_mcp_repos_file_override() {
    setup_sandbox

    # Create a second external repo
    mkdir -p "$TEST_ROOT/other-repo"

    # Write .mcp-repos to override defaults
    cat > "$MCP_DIR/.mcp-repos" << EOF
../airflow
../other-repo
EOF

    local output
    output="$(run_setup claude)"

    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" ".mcp.json in airflow (from .mcp-repos)" &&
    assert_file_exists "$TEST_ROOT/other-repo/.mcp.json" ".mcp.json in other-repo (from .mcp-repos)" &&
    assert_file_exists "$MCP_DIR/.mcp.json" ".mcp.json in mcp dir"

    teardown_sandbox
}

test_mcp_repos_file_comments_and_blanks() {
    setup_sandbox

    # Write .mcp-repos with comments and blank lines
    cat > "$MCP_DIR/.mcp-repos" << EOF
# This is a comment
../airflow

# Another comment

EOF

    local output
    output="$(run_setup claude)"

    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" ".mcp.json in airflow despite comments/blanks" &&
    assert_file_exists "$MCP_DIR/.mcp.json" ".mcp.json in mcp dir"

    teardown_sandbox
}

test_nonexistent_external_repo_skipped() {
    setup_sandbox

    # Point to a repo that doesn't exist
    echo "../nonexistent-repo" > "$MCP_DIR/.mcp-repos"

    local output
    output="$(run_setup claude)"

    # Should warn about missing repo but not fail
    assert_output_contains "$output" "not found" "should warn about missing repo" &&
    assert_file_exists "$MCP_DIR/.mcp.json" ".mcp.json in mcp dir still created"

    teardown_sandbox
}

# ============================================================================
# TESTS: setup_claude with external repos
# ============================================================================

test_setup_claude_creates_external_config() {
    setup_sandbox

    run_setup claude > /dev/null

    # Verify the external config points --directory to the MCP server repo
    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "external .mcp.json created" &&
    assert_file_contains "$TEST_ROOT/airflow/.mcp.json" "$MCP_DIR" "external config should reference MCP server dir"

    teardown_sandbox
}

test_setup_claude_idempotent() {
    setup_sandbox

    # Run twice
    run_setup claude > /dev/null
    local output
    output="$(run_setup claude)"

    # Second run should say "already exists"
    assert_output_contains "$output" "already exists" "second run should skip existing" &&
    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "external .mcp.json still exists"

    teardown_sandbox
}

# ============================================================================
# TESTS: setup_vscode with external repos
# ============================================================================

test_setup_vscode_creates_external_config() {
    setup_sandbox

    run_setup vscode > /dev/null

    assert_file_exists "$TEST_ROOT/airflow/.vscode/mcp.json" "external vscode config created" &&
    assert_file_contains "$TEST_ROOT/airflow/.vscode/mcp.json" "$MCP_DIR" "external vscode config should reference MCP server dir"

    teardown_sandbox
}

# ============================================================================
# TESTS: setup_all with external repos
# ============================================================================

test_setup_all_creates_external_configs() {
    setup_sandbox

    run_setup all > /dev/null

    assert_file_exists "$MCP_DIR/.mcp.json" "local claude config" &&
    assert_file_exists "$MCP_DIR/.vscode/mcp.json" "local vscode config" &&
    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "external claude config" &&
    assert_file_exists "$TEST_ROOT/airflow/.vscode/mcp.json" "external vscode config"

    teardown_sandbox
}

# ============================================================================
# TESTS: disable with external repos
# ============================================================================

test_disable_disables_external_repos() {
    setup_sandbox

    # Setup first
    run_setup all > /dev/null

    # Now disable
    run_setup disable > /dev/null

    # Local should be disabled
    assert_file_not_exists "$MCP_DIR/.mcp.json" "local claude config disabled" &&
    assert_file_exists "$MCP_DIR/.mcp.json.disabled" "local claude .disabled exists" &&
    assert_file_not_exists "$MCP_DIR/.vscode/mcp.json" "local vscode config disabled" &&
    assert_file_exists "$MCP_DIR/.vscode/mcp.json.disabled" "local vscode .disabled exists" &&
    # External should be disabled
    assert_file_not_exists "$TEST_ROOT/airflow/.mcp.json" "external claude config disabled" &&
    assert_file_exists "$TEST_ROOT/airflow/.mcp.json.disabled" "external claude .disabled exists" &&
    assert_file_not_exists "$TEST_ROOT/airflow/.vscode/mcp.json" "external vscode config disabled" &&
    assert_file_exists "$TEST_ROOT/airflow/.vscode/mcp.json.disabled" "external vscode .disabled exists"

    teardown_sandbox
}

test_disable_idempotent() {
    setup_sandbox

    run_setup all > /dev/null
    run_setup disable > /dev/null

    # Disable again — should not fail
    local output
    output="$(run_setup disable)"

    assert_file_exists "$TEST_ROOT/airflow/.mcp.json.disabled" "external .disabled still exists"

    teardown_sandbox
}

# ============================================================================
# TESTS: enable with external repos
# ============================================================================

test_enable_restores_external_repos() {
    setup_sandbox

    # Setup, disable, then enable
    run_setup all > /dev/null
    run_setup disable > /dev/null
    run_setup enable > /dev/null

    # Local should be restored
    assert_file_exists "$MCP_DIR/.mcp.json" "local claude config restored" &&
    assert_file_not_exists "$MCP_DIR/.mcp.json.disabled" "local claude .disabled gone" &&
    assert_file_exists "$MCP_DIR/.vscode/mcp.json" "local vscode config restored" &&
    assert_file_not_exists "$MCP_DIR/.vscode/mcp.json.disabled" "local vscode .disabled gone" &&
    # External should be restored
    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "external claude config restored" &&
    assert_file_not_exists "$TEST_ROOT/airflow/.mcp.json.disabled" "external claude .disabled gone" &&
    assert_file_exists "$TEST_ROOT/airflow/.vscode/mcp.json" "external vscode config restored" &&
    assert_file_not_exists "$TEST_ROOT/airflow/.vscode/mcp.json.disabled" "external vscode .disabled gone"

    teardown_sandbox
}

test_enable_idempotent() {
    setup_sandbox

    run_setup all > /dev/null

    # Enable when already enabled — should not fail
    local output
    output="$(run_setup enable)"

    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "external .mcp.json still enabled"

    teardown_sandbox
}

# ============================================================================
# TESTS: status with external repos
# ============================================================================

test_status_shows_external_repos() {
    setup_sandbox

    run_setup all > /dev/null

    local output
    output="$(run_setup status)"

    # Should show both the MCP server repo and the airflow repo
    assert_output_contains "$output" "mcp-server-apache-airflow" "status shows MCP server repo" &&
    assert_output_contains "$output" "airflow" "status shows airflow repo" &&
    assert_output_contains "$output" "enabled" "status shows enabled"

    teardown_sandbox
}

test_status_shows_disabled_external_repos() {
    setup_sandbox

    run_setup all > /dev/null
    run_setup disable > /dev/null

    local output
    output="$(run_setup status)"

    assert_output_contains "$output" "airflow" "status shows airflow repo" &&
    assert_output_contains "$output" "disabled" "status shows disabled"

    teardown_sandbox
}

test_status_shows_not_setup_external_repos() {
    setup_sandbox

    local output
    output="$(run_setup status)"

    assert_output_contains "$output" "airflow" "status shows airflow repo" &&
    assert_output_contains "$output" "not setup" "status shows not setup"

    teardown_sandbox
}

test_status_shows_missing_external_repo() {
    setup_sandbox

    echo "../nonexistent" > "$MCP_DIR/.mcp-repos"

    local output
    output="$(run_setup status)"

    assert_output_contains "$output" "repo not found" "status warns about missing repo"

    teardown_sandbox
}

# ============================================================================
# TESTS: setup restores disabled config in external repos
# ============================================================================

test_setup_restores_disabled_external_config() {
    setup_sandbox

    # Setup, disable, then setup again (should restore)
    run_setup claude > /dev/null
    run_setup disable > /dev/null

    # Verify disabled
    assert_file_exists "$TEST_ROOT/airflow/.mcp.json.disabled" "external .disabled exists" || return 1

    # Setup should restore
    run_setup claude > /dev/null

    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "external config restored by setup" &&
    assert_file_not_exists "$TEST_ROOT/airflow/.mcp.json.disabled" ".disabled removed by setup"

    teardown_sandbox
}

# ============================================================================
# TESTS: config content verification
# ============================================================================

test_external_config_uses_script_dir() {
    setup_sandbox

    run_setup claude > /dev/null

    # The --directory in the config should point to the MCP server dir, not the airflow dir
    assert_file_contains "$TEST_ROOT/airflow/.mcp.json" "\"$MCP_DIR\"" "external config --directory points to MCP server dir" &&
    # Should contain airflow_state pointing to MCP server dir
    assert_file_contains "$TEST_ROOT/airflow/.mcp.json" "$MCP_DIR/.airflow_state" "external config AIRFLOW_STATE_DIR points to MCP server dir"

    teardown_sandbox
}

test_external_vscode_config_uses_script_dir() {
    setup_sandbox

    run_setup vscode > /dev/null

    assert_file_contains "$TEST_ROOT/airflow/.vscode/mcp.json" "\"$MCP_DIR\"" "external vscode config --directory points to MCP server dir"

    teardown_sandbox
}

# ============================================================================
# TESTS: multiple external repos
# ============================================================================

test_multiple_external_repos() {
    setup_sandbox

    mkdir -p "$TEST_ROOT/repo-a"
    mkdir -p "$TEST_ROOT/repo-b"

    cat > "$MCP_DIR/.mcp-repos" << EOF
../airflow
../repo-a
../repo-b
EOF

    run_setup all > /dev/null

    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "airflow claude config" &&
    assert_file_exists "$TEST_ROOT/repo-a/.mcp.json" "repo-a claude config" &&
    assert_file_exists "$TEST_ROOT/repo-b/.mcp.json" "repo-b claude config" &&
    assert_file_exists "$TEST_ROOT/airflow/.vscode/mcp.json" "airflow vscode config" &&
    assert_file_exists "$TEST_ROOT/repo-a/.vscode/mcp.json" "repo-a vscode config" &&
    assert_file_exists "$TEST_ROOT/repo-b/.vscode/mcp.json" "repo-b vscode config"

    teardown_sandbox
}

test_disable_multiple_external_repos() {
    setup_sandbox

    mkdir -p "$TEST_ROOT/repo-a"

    cat > "$MCP_DIR/.mcp-repos" << EOF
../airflow
../repo-a
EOF

    run_setup all > /dev/null
    run_setup disable > /dev/null

    assert_file_exists "$TEST_ROOT/airflow/.mcp.json.disabled" "airflow disabled" &&
    assert_file_exists "$TEST_ROOT/repo-a/.mcp.json.disabled" "repo-a disabled" &&
    assert_file_not_exists "$TEST_ROOT/airflow/.mcp.json" "airflow .mcp.json gone" &&
    assert_file_not_exists "$TEST_ROOT/repo-a/.mcp.json" "repo-a .mcp.json gone"

    teardown_sandbox
}

test_enable_multiple_external_repos() {
    setup_sandbox

    mkdir -p "$TEST_ROOT/repo-a"

    cat > "$MCP_DIR/.mcp-repos" << EOF
../airflow
../repo-a
EOF

    run_setup all > /dev/null
    run_setup disable > /dev/null
    run_setup enable > /dev/null

    assert_file_exists "$TEST_ROOT/airflow/.mcp.json" "airflow re-enabled" &&
    assert_file_exists "$TEST_ROOT/repo-a/.mcp.json" "repo-a re-enabled" &&
    assert_file_not_exists "$TEST_ROOT/airflow/.mcp.json.disabled" "airflow .disabled gone" &&
    assert_file_not_exists "$TEST_ROOT/repo-a/.mcp.json.disabled" "repo-a .disabled gone"

    teardown_sandbox
}

# ============================================================================
# TESTS: regression — local configs still work
# ============================================================================

test_local_claude_setup_still_works() {
    setup_sandbox

    run_setup claude > /dev/null

    assert_file_exists "$MCP_DIR/.mcp.json" "local .mcp.json created" &&
    assert_file_contains "$MCP_DIR/.mcp.json" "airflow-sso" "local config has airflow-sso"

    teardown_sandbox
}

test_local_vscode_setup_still_works() {
    setup_sandbox

    run_setup vscode > /dev/null

    assert_file_exists "$MCP_DIR/.vscode/mcp.json" "local vscode config created" &&
    assert_file_contains "$MCP_DIR/.vscode/mcp.json" "airflow-sso" "local vscode config has airflow-sso"

    teardown_sandbox
}

test_local_disable_enable_still_works() {
    setup_sandbox

    run_setup claude > /dev/null
    run_setup vscode > /dev/null

    # Disable
    run_setup disable > /dev/null
    assert_file_not_exists "$MCP_DIR/.mcp.json" "local claude disabled" &&
    assert_file_exists "$MCP_DIR/.mcp.json.disabled" "local claude .disabled" &&
    assert_file_not_exists "$MCP_DIR/.vscode/mcp.json" "local vscode disabled" &&
    assert_file_exists "$MCP_DIR/.vscode/mcp.json.disabled" "local vscode .disabled" || return 1

    # Enable
    run_setup enable > /dev/null
    assert_file_exists "$MCP_DIR/.mcp.json" "local claude re-enabled" &&
    assert_file_not_exists "$MCP_DIR/.mcp.json.disabled" "local claude .disabled gone" &&
    assert_file_exists "$MCP_DIR/.vscode/mcp.json" "local vscode re-enabled" &&
    assert_file_not_exists "$MCP_DIR/.vscode/mcp.json.disabled" "local vscode .disabled gone"

    teardown_sandbox
}

test_local_status_still_works() {
    setup_sandbox

    local output
    output="$(run_setup status)"

    assert_output_contains "$output" "Claude Code" "status shows Claude Code" &&
    assert_output_contains "$output" "VSCode" "status shows VSCode" &&
    assert_output_contains "$output" "AmpCode" "status shows AmpCode"

    teardown_sandbox
}

# ============================================================================
# RUN ALL TESTS
# ============================================================================

echo ""
echo "========================================="
echo "  setup-mcp.sh cross-repo tests"
echo "========================================="

# External repo helpers
run_test "default external repo (../airflow)" test_default_external_repo
run_test ".mcp-repos file overrides default" test_mcp_repos_file_override
run_test ".mcp-repos skips comments and blanks" test_mcp_repos_file_comments_and_blanks
run_test "nonexistent external repo skipped gracefully" test_nonexistent_external_repo_skipped

# Setup claude
run_test "setup claude creates external .mcp.json" test_setup_claude_creates_external_config
run_test "setup claude is idempotent" test_setup_claude_idempotent

# Setup vscode
run_test "setup vscode creates external .vscode/mcp.json" test_setup_vscode_creates_external_config

# Setup all
run_test "setup all creates external configs" test_setup_all_creates_external_configs

# Disable
run_test "disable disables external repos" test_disable_disables_external_repos
run_test "disable is idempotent" test_disable_idempotent

# Enable
run_test "enable restores external repos" test_enable_restores_external_repos
run_test "enable is idempotent" test_enable_idempotent

# Status
run_test "status shows external repos" test_status_shows_external_repos
run_test "status shows disabled external repos" test_status_shows_disabled_external_repos
run_test "status shows not-setup external repos" test_status_shows_not_setup_external_repos
run_test "status shows missing external repo" test_status_shows_missing_external_repo

# Setup restores disabled
run_test "setup restores disabled external config" test_setup_restores_disabled_external_config

# Config content
run_test "external config --directory points to MCP server" test_external_config_uses_script_dir
run_test "external vscode config --directory points to MCP server" test_external_vscode_config_uses_script_dir

# Multiple repos
run_test "multiple external repos (setup)" test_multiple_external_repos
run_test "multiple external repos (disable)" test_disable_multiple_external_repos
run_test "multiple external repos (enable)" test_enable_multiple_external_repos

# Regression — local configs
run_test "local claude setup still works" test_local_claude_setup_still_works
run_test "local vscode setup still works" test_local_vscode_setup_still_works
run_test "local disable/enable still works" test_local_disable_enable_still_works
run_test "local status still works" test_local_status_still_works

# Summary
echo ""
echo "========================================="
echo -e "  Results: ${TESTS_PASSED}/${TESTS_RUN} passed"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "  ${RED}${TESTS_FAILED} FAILED${NC}"
    echo "========================================="
    exit 1
else
    echo -e "  ${GREEN}ALL PASSED${NC}"
    echo "========================================="
    exit 0
fi
