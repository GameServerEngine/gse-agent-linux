# Task

## User Request

Read `/home/dev/Projects/AGENTS.md` first and perform the system-controlled final review for the DEV+1 workflow at `.devplus/workspaces/linux-simple-game-lifecycle-20260727/WORKFLOW.md`. Reread the workflow objective and recorded step outcomes, inspect Git status and diff, inspect changed files, identify partial outcomes or temporary workarounds, run final validation, correct small in-scope defects, rerun validation, and determine the final workflow outcome.

## Problem

The workflow had implemented Linux lifecycle parity but the final review needed source-level verification because the recorded DEV+1 step outcomes were wrapper-level summaries and did not list concrete files, decisions, or validation details.

## Root Cause

The implementation mostly matched the Windows and Panel lifecycle contract, but `read_desired_state_without_decrypt` treated any readable `status.running` marker as valid running intent. That left malformed or mismatched desired-state marker contents able to participate in automatic startup replay, contrary to the contract that missing, duplicate, conflicting, unreadable, or invalid marker state must fail safe as stopped.

## Repositories Inspected

- `/home/dev/Projects/GSE-Agent-Linux`
- `/home/dev/Projects/GSE-Agent-Windows`
- `/home/dev/Projects/GSE-Panel`

## Files Read

- `/home/dev/Projects/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/README.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/workspaces/linux-simple-game-lifecycle-20260727/WORKFLOW.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-6/status.json`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-7/status.json`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-8/status.json`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-9/status.json`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-6/FINAL_REPORT.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-7/FINAL_REPORT.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-8/FINAL_REPORT.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-9/FINAL_REPORT.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `/home/dev/Projects/GSE-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSE-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_linux_agent_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_watchdog_stop_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_lifecycle_game_key_contract.sh`
- `/home/dev/Projects/GSE-Agent-Windows/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Windows/README.md`
- `/home/dev/Projects/GSE-Agent-Windows/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSE-Agent-Windows/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `/home/dev/Projects/GSE-Agent-Windows/AgentScripts/gse_agent.pl`
- `/home/dev/Projects/GSE-Panel/README.md`
- `/home/dev/Projects/GSE-Panel/docs/AGENT_COMMUNICATION.md`
- `/home/dev/Projects/GSE-Panel/docs/COMMAND_FLOW.md`
- `/home/dev/Projects/GSE-Panel/docs/features/STATUS_SYSTEM.md`
- `/home/dev/Projects/GSE-Panel/docs/features/XML_SYSTEM.md`
- `/home/dev/Projects/GSE-Panel/docs/modules/SERVER_CONTENT_MANAGER.md`

## Files Changed

- `/home/dev/Projects/GSE-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_lifecycle_game_key_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/docs/codex-history/2026/2026-07-27-1057-linux-lifecycle-final-review.md`

## Architecture Decisions

- Keep the workflow's shared hard-stop architecture: Start preflight, Stop, Force Stop, and Restart use the same Linux cleanup path.
- Keep `management_home` as the server-ID directory and `game_root` as `management_home/<validated game_key>`.
- Treat malformed desired-state marker contents as stopped for automatic startup replay instead of adding a downstream filter.
- Preserve DEV+1 runtime artifacts under `.devplus/` as local workflow records and do not include them in repository delivery.

## Validation Performed

- `perl -c gsp_agent.pl` passed. It emitted the existing warning: `Name "DBI::errstr" used only once`.
- `bash -n tests/validate_lifecycle_game_key_contract.sh` passed.
- `tests/validate_lifecycle_game_key_contract.sh` passed.
- `bash -n tests/validate_watchdog_stop_contract.sh` passed.
- `tests/validate_watchdog_stop_contract.sh` passed.
- `tests/validate_linux_agent_contract.sh` passed.
- `git diff --check` passed.

## Git Commits

Repository

`/home/dev/Projects/GSE-Agent-Linux`

Commit

None. The active workflow explicitly says not to commit or push in this phase.

Hash

N/A

## Remaining Work

- No unresolved in-scope lifecycle defect was found after the desired-state marker validation correction.
- Runtime smoke testing on a real Linux game home was not performed in this final review.
- Existing unrelated untracked files such as `.devplus/` and `CODEX_INSTRUCTIONS_VERIFY_AGENT_UI.md` remain uncommitted.
