# Task

## User Request

Perform DEV+1 workflow Step 04 for `GSE-Agent-Linux`: implement game-key path parity and definitive Linux tests. Keep `management_home` as the server-ID directory, resolve game executable and payload paths beneath `management_home/<validated game_key>`, reject unsafe keys and escaping paths, keep GSP management artifacts outside game root, validate lifecycle behavior, update documentation, and do not commit or push.

## Problem

Linux lifecycle Start still accepted `home_path` as the effective payload root unless the Panel supplied a game-key-prefixed run directory. The agent did not validate XML `game_key` itself, startup replay could relaunch a stopped/crash-looped home from a stale startup flag, and some generated install control scripts could be created in payload destinations.

## Root Cause

The Linux RPC handlers lacked a local game-root derivation boundary. `universal_start_without_decrypt` trusted `home_path` and `run_dir` without proving `game_root = management_home/<game_key>`, and install/update helpers wrote temporary management scripts in the destination path instead of the agent temp runtime area.

## Repositories Inspected

- `/home/dev/Projects/GSE-Agent-Linux`
- `/home/dev/Projects/GSE-Agent-Windows`
- `/home/dev/Projects/GSE-Panel`

## Files Read

- `/home/dev/Projects/AGENTS.md`
- `AGENTS.md`
- `README.md`
- `.devplus/workspaces/linux-simple-game-lifecycle-20260727/WORKFLOW.md`
- `docs/PANEL_INTEGRATION.md`
- `documentation/agent-guide.md`
- `docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `tests/validate_watchdog_stop_contract.sh`
- `tests/validate_linux_agent_contract.sh`
- `gsp_agent.pl`
- `/home/dev/Projects/GSE-Agent-Windows/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `/home/dev/Projects/GSE-Agent-Windows/AgentScripts/gse_agent.pl`
- `/home/dev/Projects/GSE-Panel/.devplus/workspaces/panel-game-lifecycle-layout-20260727/WORKFLOW.md`
- `/home/dev/Projects/GSE-Panel/includes/game_path_helpers.php`
- `/home/dev/Projects/GSE-Panel/gsp_api.php`

## Files Changed

- `gsp_agent.pl`
- `tests/validate_lifecycle_game_key_contract.sh`
- `tests/validate_linux_agent_contract.sh`
- `docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `docs/PANEL_INTEGRATION.md`
- `documentation/agent-guide.md`
- `docs/codex-history/2026/2026-07-27-1048-linux-game-key-path-parity-tests.md`

## Architecture Decisions

- Mirrored the Panel `game_key` validation contract in Linux: safe single path component, no traversal, separators, control characters, drive prefixes, colons, reserved device names, trailing dot, or unsafe characters.
- Kept `home_path` as `management_home` for lifecycle state, watchdog, PID files, bot definition, Server Content management runtime, and hard-stop cleanup.
- Derived `game_root` locally in Start and resolved the game working directory beneath it.
- Accepted both Panel transitional `run_dir=<game_key>/...` and future game-root-relative `run_dir=...` without allowing escape from `game_root`.
- Made automatic startup replay require a valid `status.running` marker so stopped or crash-looped homes are not revived by agent restart.
- Moved generated install control scripts to the agent temp area instead of payload destinations. No migration or folder-moving code was added.

## Validation Performed

- `perl -c gsp_agent.pl`
- `bash -n tests/validate_linux_agent_contract.sh tests/validate_watchdog_stop_contract.sh tests/validate_lifecycle_game_key_contract.sh`
- `tests/validate_lifecycle_game_key_contract.sh`
- `tests/validate_watchdog_stop_contract.sh`
- `tests/validate_linux_agent_contract.sh`
- `git diff --check`

## Git Commits

Repository

`/home/dev/Projects/GSE-Agent-Linux`

Commit

Not committed. This DEV+1 phase explicitly defers commits and pushes until coordinated validation across repositories.

Hash

N/A

## Remaining Work

- Run the documented non-production Linux smoke test after the coordinated Panel, Windows, and Linux release is deployed.
- Keep the current uncommitted repository state for later coordinated validation and delivery.
