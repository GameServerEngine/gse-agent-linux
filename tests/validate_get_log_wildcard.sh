#!/usr/bin/env bash
# Runs the get_log wildcard resolution test against agent_core.pl.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec perl "$repo_root/tests/validate_get_log_wildcard.pl" "$repo_root/agent_core.pl"
