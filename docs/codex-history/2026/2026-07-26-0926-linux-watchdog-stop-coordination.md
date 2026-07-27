# Task

## User Request

Perform DEV+1 workflow step 01 for `/home/dev/Projects/GSE-Agent-Linux`: implement and validate Linux watchdog stop coordination so the generated startup watchdog uses the supplied status-hint path, exits on `STOPPING`, `FORCE_STOPPING`, or `STOPPED`, records `watchdog.pid`, cleans home PID files in watchdog/bot/game order, updates focused tests and lifecycle documentation, creates a codex-history record, validates the Perl/Linux source, and does not stage, commit, push, stop, or restart services.

## Problem

The Linux generated startup watchdog could continue its unconditional loop during shutdown. If the game or sidecar was absent while stop or force-stop cleanup was running, the watchdog could relaunch it before the shutdown completed.

## Root Cause

`create_screen_cmd_loop` accepted `$status_hint_file`, but the generated shell did not read that file before launch or relaunch attempts. The generated watchdog also did not record its own home PID, and home PID cleanup only processed `bot.pid` and `game.pid`, leaving no targeted home-level cleanup path for the watchdog itself.

## Repositories Inspected

- `/home/dev/Projects/GSE-Agent-Linux`
- `/home/dev/Projects/GSE-Agent-Windows`
- `/home/dev/Projects/GSE-Panel`

## Files Read

- `/home/dev/Projects/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/README.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/workspaces/linux-watchdog-stop-20260726/WORKFLOW.md`
- `/home/dev/Projects/GSE-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/AGENT_ACTIVITY_EVENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/codex-history/2026/2026-07-11-0005-agent-lifecycle-parity.md`
- `/home/dev/Projects/GSE-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_linux_agent_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_steamcmd_bootstrap_payload.sh`
- `/home/dev/Projects/GSE-Agent-Windows/docs/PROCESS_MANAGEMENT.md`
- `/home/dev/Projects/GSE-Agent-Windows/AgentScripts/gse_agent.pl`
- `/home/dev/Projects/GSE-Panel/docs/AGENT_COMMUNICATION.md`

## Files Changed

- `/home/dev/Projects/GSE-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_watchdog_stop_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_linux_agent_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/codex-history/2026/2026-07-26-0926-linux-watchdog-stop-coordination.md`

## Architecture Decisions

- Keep the Panel authoritative and leave XML-RPC request/return conventions unchanged.
- Keep Linux-native `screen`, sudo/user, process, and port handling intact.
- Use the existing agent-owned status hint file as the lifecycle contract between stop/force-stop and the generated watchdog.
- Track the main startup watchdog in `<game_home>/watchdog.pid`; do not place it in `_gsp_content/runtime/server_content.pids`, which remains reserved for server-content hook processes.
- Kill `watchdog.pid` before `bot.pid` and `game.pid` through the existing targeted Linux PID escalation helper.
- Write `STARTING` before launching the guarded watchdog so a stale `STOPPED` hint from a prior successful stop cannot block an intentional start.

## Validation Performed

- `perl -c gsp_agent.pl` passed. Perl emitted the pre-existing warning `Name "DBI::errstr" used only once`.
- `bash -n tests/validate_watchdog_stop_contract.sh` passed.
- `tests/validate_watchdog_stop_contract.sh` passed.
- `tests/validate_linux_agent_contract.sh` passed. Perl emitted the same pre-existing `DBI::errstr` warning during its syntax check.
- `git diff --check -- gsp_agent.pl tests/validate_linux_agent_contract.sh documentation/agent-guide.md docs/PANEL_INTEGRATION.md` passed.
- `git diff --no-index --check /dev/null tests/validate_watchdog_stop_contract.sh` passed for the new test file.
- `git diff --no-index --check /dev/null docs/codex-history/2026/2026-07-26-0926-linux-watchdog-stop-coordination.md` passed for the new history file.
- `git status --short` reviewed. Pre-existing unrelated untracked files remain unstaged and untouched.

## Git Commits

Repository

`GSE-Agent-Linux`

Commit

None. Operator-level workflow instructions explicitly forbid staging, committing, or pushing for this step.

Hash

N/A

## Remaining Work

- Perform installed-host runtime validation later with real game and sidecar processes to verify stop, force-stop, and relaunch race behavior outside this source-only workflow step.
