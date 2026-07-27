# Task

## User Request

Read `/home/dev/Projects/AGENTS.md` first and execute only Step 01 of
`/home/dev/Projects/GSE-Agent-Linux/.devplus/workspaces/linux-simple-game-lifecycle-20260727/WORKFLOW.md`: inspect the Linux lifecycle, reconcile it with the
Windows and Panel lifecycle contract, preserve existing uncommitted work, and
update durable Linux documentation with the authoritative filenames, state
transitions, hard-stop order, Start preflight, protected-process rules,
crash-loop behavior, optional bot behavior, verification criteria, and
game-key payload boundary.

## Problem

The Linux repository did not have a durable lifecycle contract document matching
the Windows and Panel phase contracts. Existing Linux docs described the recent
legacy status-hint mitigation, but they did not map all current lifecycle paths
or clearly identify the target `status.running`/`status.stopped`,
`management_home`, and `game_root` contract.

## Root Cause

Lifecycle behavior was still documented through older operational notes and
recent stop-coordination edits. The current Linux implementation also keeps
competing state sources in `startups/`, `runtime_status/`, home PID files,
screen sessions, Server Content PID files, and port listeners, so the next
implementation steps needed a single inspection-backed contract.

## Repositories Inspected

- `/home/dev/Projects/GSE-Agent-Linux`
- `/home/dev/Projects/GSE-Agent-Windows`
- `/home/dev/Projects/GSE-Panel`

## Files Read

- `/home/dev/Projects/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/README.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/workspaces/linux-simple-game-lifecycle-20260727/WORKFLOW.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/inspections/inspection-20260727T150523Z-9ef3df97/PROJECT_STATUS.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSE-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/agent-modernization-step-1-divergence-report.md`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_linux_agent_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_watchdog_stop_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/workspaces/linux-watchdog-stop-20260726/reports/FINAL_REPORT.md`
- `/home/dev/Projects/GSE-Agent-Windows/.devplus/workspaces/windows-simple-game-lifecycle-20260727/WORKFLOW.md`
- `/home/dev/Projects/GSE-Agent-Windows/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `/home/dev/Projects/GSE-Agent-Windows/docs/PROCESS_MANAGEMENT.md`
- `/home/dev/Projects/GSE-Agent-Windows/.devplus/codex-runs/gaw-8/FINAL_REPORT.md`
- `/home/dev/Projects/GSE-Agent-Windows/.devplus/inspections/inspection-20260727T150346Z-570bf289/PROJECT_STATUS.md`
- `/home/dev/Projects/GSE-Panel/.devplus/workspaces/panel-game-lifecycle-layout-20260727/WORKFLOW.md`
- `/home/dev/Projects/GSE-Panel/.devplus/inspections/inspection-20260727T150453Z-d8693cb4/PROJECT_STATUS.md`
- `/home/dev/Projects/GSE-Panel/docs/AGENT_COMMUNICATION.md`
- `/home/dev/Projects/GSE-Panel/docs/COMMAND_FLOW.md`
- `/home/dev/Projects/GSE-Panel/docs/agents/LINUX_AGENT.md`
- `/home/dev/Projects/GSE-Panel/docs/agents/WINDOWS_AGENT.md`
- `/home/dev/Projects/GSE-Panel/docs/modules/SERVER_CONTENT_MANAGER.md`

## Files Changed

- `/home/dev/Projects/GSE-Agent-Linux/README.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/codex-history/2026/2026-07-27-1017-linux-lifecycle-contract-inspection.md`

## Architecture Decisions

- Linux must match the Windows and Panel external lifecycle contract while using
  native Linux process, signal, process-group, `/proc`, and port-owner
  mechanics.
- `management_home` is the server-ID directory.
- `game_root` is `management_home/<validated game_key>`.
- Desired state is only `status.running` or `status.stopped` in
  `management_home`; legacy `startups/status-<home_id>` hints are compatibility
  only.
- Actual state must be verified from screen, watchdog PID, bot PID, game PID,
  and TCP/UDP port ownership evidence.
- Server Content management runtime belongs in `management_home`, not beneath
  `game_root`.

## Validation Performed

- `perl -c gsp_agent.pl`
- `bash -n tests/validate_linux_agent_contract.sh tests/validate_watchdog_stop_contract.sh`
- `tests/validate_watchdog_stop_contract.sh`
- `tests/validate_linux_agent_contract.sh`

## Git Commits

Repository

`/home/dev/Projects/GSE-Agent-Linux`

Commit

Not committed. The current workflow explicitly defers staging, commits, and
pushes until coordinated validation across repositories.

Hash

Not applicable.

## Remaining Work

- Implement atomic `status.running`/`status.stopped` handling.
- Replace legacy status-hint control.
- Implement one shared Linux hard-stop path.
- Replace the generated watchdog with a 30-second readable supervisor.
- Implement the 120-second crash-loop shutdown.
- Move active game payload paths beneath validated `game_key`.
- Add focused lifecycle and game-root tests in later workflow steps.
