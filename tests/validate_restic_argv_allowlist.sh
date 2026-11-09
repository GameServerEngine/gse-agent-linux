#!/usr/bin/env bash
# Runs the restic argv allowlist test against agent_core.pl.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec perl "$repo_root/tests/validate_restic_argv_allowlist.pl" "$repo_root/agent_core.pl"
