# Task

## User Request

Perform DEV+1 workflow Step 02 for GSE-Agent-Linux: implement atomic desired
state, Start preflight cleanup, and one authoritative Linux hard-stop path
without committing or pushing.

## Problem

The Linux lifecycle still used legacy startup status hints and split cleanup
logic across Start, Stop, Force Stop, restart verification, home PID cleanup,
tracked PID cleanup, and port-owner cleanup.

## Root Cause

The active Perl control path treated `startups/status-<home_id>` hints as
shutdown/startup coordination and duplicated process termination in multiple
call sites. That made Stop, Force Stop, Restart, and Start preflight diverge
from the Windows/Panel contract requiring `status.running` or `status.stopped`
in the management home plus one verified hard-stop operation.

## Repositories Inspected

- `/home/dev/Projects/GSE-Agent-Linux`
- `/home/dev/Projects/GSE-Agent-Windows`
- `/home/dev/Projects/GSE-Panel`

## Files Read

- `/home/dev/Projects/AGENTS.md`
- `AGENTS.md`
- `README.md`
- `.devplus/workspaces/linux-simple-game-lifecycle-20260727/WORKFLOW.md`
- `documentation/agent-guide.md`
- `docs/PANEL_INTEGRATION.md`
- `docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `/home/dev/Projects/GSE-Agent-Windows/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `/home/dev/Projects/GSE-Panel/.devplus/workspaces/panel-game-lifecycle-layout-20260727/WORKFLOW.md`
- `/home/dev/Projects/GSE-Panel/docs/AGENT_COMMUNICATION.md`
- `gsp_agent.pl`
- `tests/validate_watchdog_stop_contract.sh`
- `tests/validate_linux_agent_contract.sh`

## Files Changed

- `gsp_agent.pl`
- `tests/validate_watchdog_stop_contract.sh`
- `docs/PANEL_INTEGRATION.md`
- `documentation/agent-guide.md`
- `docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `docs/codex-history/2026/2026-07-27-1031-linux-hard-stop-state.md`

Pre-existing uncommitted changes in `README.md`,
`tests/validate_linux_agent_contract.sh`, and other untracked files were
preserved.

## Architecture Decisions

- Use `status.running` and `status.stopped` in `management_home` as the only
  desired-state markers.
- Treat missing, duplicate, conflicting, unreadable, or invalid desired state as
  stopped.
- Make Start call the shared hard-stop helper as a stopped-state preflight
  before writing the automatic-start registration or launching the watchdog.
- Make Stop and Force Stop delegate to the same hard-stop helper.
- Keep persistent automatic-start files under `startups/` separate from runtime
  desired state.
- Discover all TCP and UDP owners of the assigned game port and classify them
  before killing.
- Refuse protected or ambiguous port owners with evidence instead of killing.
- Remove PID/timestamp/runtime files only after verification proves the screen,
  tracked PIDs, and assigned port owners are absent.

## Validation Performed

- `perl -c gsp_agent.pl`
- `bash -n tests/validate_watchdog_stop_contract.sh`
- `tests/validate_watchdog_stop_contract.sh`
- `bash -n tests/validate_linux_agent_contract.sh`
- `tests/validate_linux_agent_contract.sh`

## Git Commits

Repository

`/home/dev/Projects/GSE-Agent-Linux`

Commit

Not committed. This workflow phase explicitly says do not stage, commit, or
push.

Hash

N/A

## Remaining Work

- Step 03 must replace the generated watchdog with the short readable parity
  supervisor, switch to the 30-second loop, add 120-second crash-loop shutdown,
  and move the active watchdog script to `management_home/serverStart.sh`.
- Step 04 must implement game-key payload path parity and definitive injected
  lifecycle tests.
