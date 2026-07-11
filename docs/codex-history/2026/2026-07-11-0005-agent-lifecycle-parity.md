# Task

## User Request

Workflow `windows-agent-modernization`, step 3 of 6: Match watchdog, PID, start/stop/restart/update behavior across agents, validate, commit and push.

## Problem

Linux and Windows lifecycle cleanup were close but not equivalent for legacy helper/watchdog PID handling. Windows imported legacy `_alsoRun.pid` entries into the server-content PID cleanup path before normal stop and restart cleanup, while Linux only cleaned the modern `_gsp_content/runtime/server_content.pids` registry and generated `game.pid`/`bot.pid` files.

## Root Cause

The Linux server-content cleanup path did not include the Windows legacy compatibility bridge. Legacy helper PIDs could remain outside the modern cleanup registry, so stop, restart, and force-stop behavior could diverge between agents when older sidecar files were present.

## Repositories Inspected

- `/home/dev/Projects/GSP/Panel`
- `/home/dev/Projects/GSP/GSP-Agent-Linux`
- `/home/dev/Projects/GSP/GSP-Agent-Windows`
- `/home/dev/Projects/GSP/references/OGP` through existing divergence documentation only

## Files Read

- `/home/dev/Projects/GSP/AGENTS.md`
- `/home/dev/Projects/GSP/Panel/README.md`
- `/home/dev/Projects/GSP/Panel/docs/ARCHITECTURE.md`
- `/home/dev/Projects/GSP/Panel/docs/PANEL_ARCHITECTURE.md`
- `/home/dev/Projects/GSP/Panel/docs/AGENT_COMMUNICATION.md`
- `/home/dev/Projects/GSP/Panel/docs/COMMAND_FLOW.md`
- `/home/dev/Projects/GSP/Panel/docs/UPDATE_POLICY.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/AGENT_ACTIVITY_EVENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/agent-modernization-step-1-divergence-report.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/AGENT_ARCHITECTURE.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/CYGWIN_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/COMMAND_EXECUTION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PROCESS_MANAGEMENT.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/agent_launch.sh`

## Files Changed

- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`

## Architecture Decisions

- Keep the Panel authoritative and leave protocol shape unchanged.
- Keep main game PID tracking in `runtime_status/pid-<home_id>.kv`; do not write main server watchdog PIDs into `server_content.pids`.
- Treat legacy `_alsoRun.pid` as compatibility input only and import matching helper PIDs into the server-content cleanup path before watchdog/app cleanup.
- Deduplicate server-content PID cleanup so the same helper PID is not killed repeatedly from duplicate registry lines.

## Validation Performed

- `git status --short --branch`
- `git diff --stat`
- `git diff --check -- gsp_agent.pl docs/PANEL_INTEGRATION.md documentation/agent-guide.md`
- `perl -c gsp_agent.pl` passed with pre-existing `DBI::errstr` warning.
- `bash -n gsp_agent_run`
- `php -l includes/lib_remote.php`
- `php -l modules/server/agent_interface.php`

## Git Commits

Repository

`GSP-Agent-Linux`

Commit

`Align Linux sidecar cleanup parity`

Hash

`74ff411832b7064fa6f7cc520f2e8d481b8dcee1`

## Remaining Work

- Full stop/restart/force-stop runtime validation should be performed on installed Linux and Windows hosts with real helper processes and assigned game ports.
