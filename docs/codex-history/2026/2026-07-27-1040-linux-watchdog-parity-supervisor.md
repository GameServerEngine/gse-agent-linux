# Task

## User Request

Perform DEV+1 workflow Step 03 for `/home/dev/Projects/GSE-Agent-Linux`: replace the Linux watchdog with a readable parity supervisor that is regenerated on every Start, directly owned by one named screen session, checks every 30 seconds, independently restarts the optional bot, stops on game crash loops under 120 seconds, uses native Linux process-group mechanics, avoids management artifacts beneath `game_root`, and does not stage, commit, or push during this phase.

## Problem

The active Linux watchdog generator still followed the legacy shape. It wrote an agent-root `GSP_HOME_<id>_startup_scr.sh` script, the named screen ran that extra wrapper script, the loop checked every 60 seconds, optional bot state came from legacy `_alsoRun.cmd`, and a quickly dying game could be relaunched indefinitely instead of transitioning desired state to stopped.

## Root Cause

`create_screen_cmd_loop` was the source of the generated watchdog and screen command. It still generated the old wrapper-style script and lacked the Windows/Panel parity semantics for direct `serverStart.sh` screen ownership, `bot.def`, 30-second checks, launch timestamp tracking, 120-second crash-loop shutdown, and process-group cleanup.

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
- `/home/dev/Projects/GSE-Agent-Windows/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `/home/dev/Projects/GSE-Panel/.devplus/workspaces/panel-game-lifecycle-layout-20260727/WORKFLOW.md`
- `gsp_agent.pl`
- `tests/validate_linux_agent_contract.sh`
- `tests/validate_watchdog_stop_contract.sh`

## Files Changed

- `gsp_agent.pl`
- `docs/PANEL_INTEGRATION.md`
- `documentation/agent-guide.md`
- `docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`
- `tests/validate_watchdog_stop_contract.sh`
- `docs/codex-history/2026/2026-07-27-1040-linux-watchdog-parity-supervisor.md`

## Architecture Decisions

- Generate one `management_home/serverStart.sh` watchdog on every Start and launch it directly with the existing named `screen` session.
- Keep desired state in `status.running` and `status.stopped`; the watchdog exits unless running is the only valid marker.
- Use `bot.def` as the active optional bot definition and leave `_alsoRun.cmd` as legacy cleanup-only input.
- Launch game and bot commands with `setsid` when available so stored PIDs are process-group leaders.
- Extend hard-stop PID cleanup to include managed process-group members in addition to child process trees.
- Record crash-loop evidence through the screen log instead of adding another lifecycle state authority.

## Validation Performed

- `perl -c gsp_agent.pl`
- `bash -n tests/validate_watchdog_stop_contract.sh`
- `tests/validate_watchdog_stop_contract.sh`
- `tests/validate_linux_agent_contract.sh`
- `git diff --check`

## Git Commits

Repository

`/home/dev/Projects/GSE-Agent-Linux`

Commit

Not committed. The active workflow phase explicitly says to preserve uncommitted work and not stage, commit, or push.

Hash

Not applicable.

## Remaining Work

- Step 04 still needs game-key path parity and definitive Linux tests.
- No runtime screen launch smoke test was performed in this step; validation was static and contract-script based.
