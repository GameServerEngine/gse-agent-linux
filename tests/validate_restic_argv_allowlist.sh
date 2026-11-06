#!/usr/bin/env bash
# Runs the restic argv allowlist test against gsp_agent.pl.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec perl "$repo_root/tests/validate_restic_argv_allowlist.pl" "$repo_root/gsp_agent.pl"
