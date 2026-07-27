# Task

## User Request

Perform the DEV+1 final review for `/home/dev/Projects/GSE-Agent-Linux` workflow `/home/dev/Projects/GSE-Agent-Linux/.devplus/workspaces/linux-watchdog-stop-20260726/WORKFLOW.md`: reread the objective, review recorded outcomes, inspect Git status and relevant diff, inspect created/changed/deleted files, identify unresolved partial outcomes or temporary workarounds, run final validation, correct small in-scope defects, rerun affected validation, and determine the final workflow outcome. End with the required DEV+1 result protocol.

## Problem

The workflow changed Linux watchdog stop coordination so shutdown status hints prevent watchdog relaunches. Final review needed to verify that the implementation matched the workflow contract and that the validation was strong enough to catch ordering regressions in the generated watchdog source.

## Root Cause

The original Linux watchdog source accepted a status hint path but did not consume it before launch or relaunch attempts, and home PID cleanup did not target `watchdog.pid`. During review, the remaining small defect was in the focused validation: it checked for required snippets but did not prove the generated watchdog guard appears before the game and sidecar launch commands.

## Repositories Inspected

- `/home/dev/Projects/GSE-Agent-Linux`
- `/home/dev/Projects/GSE-Agent-Windows`
- `/home/dev/Projects/GSE-Panel`

## Files Read

- `/home/dev/Projects/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/AGENTS.md`
- `/home/dev/Projects/GSE-Agent-Linux/README.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/workspaces/linux-watchdog-stop-20260726/WORKFLOW.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-4/status.json`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-4/FINAL_REPORT.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-4/verification.md`
- `/home/dev/Projects/GSE-Agent-Linux/.devplus/codex-runs/gal-4/last_message.md`
- `/home/dev/Projects/GSE-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_watchdog_stop_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_linux_agent_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSE-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSE-Agent-Linux/docs/codex-history/2026/2026-07-26-0926-linux-watchdog-stop-coordination.md`
- `/home/dev/Projects/GSE-Agent-Windows/AgentScripts/gse_agent.pl`
- `/home/dev/Projects/GSE-Agent-Windows/docs/PROCESS_MANAGEMENT.md`
- `/home/dev/Projects/GSE-Panel/docs/AGENT_COMMUNICATION.md`

## Files Changed

- `/home/dev/Projects/GSE-Agent-Linux/tests/validate_watchdog_stop_contract.sh`
- `/home/dev/Projects/GSE-Agent-Linux/docs/codex-history/2026/2026-07-26-0931-linux-watchdog-stop-final-review.md`

## Architecture Decisions

- Preserve the existing Linux agent architecture: the Panel remains authoritative, and the Linux agent executes lifecycle requests through its existing screen, sudo/user, PID, and port cleanup paths.
- Keep the runtime source fix in `create_screen_cmd_loop` and `kill_home_pid_files_without_decrypt`; do not add a secondary wrapper around stop behavior.
- Keep `watchdog.pid` as a game-home PID file, separate from `_gsp_content/runtime/server_content.pids`.
- Strengthen validation by asserting ordering in source-generated watchdog strings rather than only checking for isolated snippets.
- Do not stage, commit, or push because the workflow explicitly forbids it.

## Validation Performed

- `perl -c gsp_agent.pl` passed. Perl emitted the pre-existing warning `Name "DBI::errstr" used only once`.
- `bash -n tests/validate_watchdog_stop_contract.sh` passed.
- `tests/validate_watchdog_stop_contract.sh` passed.
- `tests/validate_linux_agent_contract.sh` passed. Perl emitted the same pre-existing `DBI::errstr` warning during its syntax check.
- `git diff --check -- gsp_agent.pl tests/validate_linux_agent_contract.sh documentation/agent-guide.md docs/PANEL_INTEGRATION.md tests/validate_watchdog_stop_contract.sh docs/codex-history/2026/2026-07-26-0926-linux-watchdog-stop-coordination.md docs/codex-history/2026/2026-07-26-0931-linux-watchdog-stop-final-review.md` passed.
- `git diff --no-index --check /dev/null tests/validate_watchdog_stop_contract.sh` passed for the new watchdog test.
- `git diff --no-index --check /dev/null docs/codex-history/2026/2026-07-26-0926-linux-watchdog-stop-coordination.md` passed for the step history record.
- `git diff --no-index --check /dev/null docs/codex-history/2026/2026-07-26-0931-linux-watchdog-stop-final-review.md` passed for this review history record.
- `git status --short` reviewed.

## Git Commits

Repository

`GSE-Agent-Linux`

Commit

None. The DEV+1 workflow explicitly forbids staging, committing, or pushing.

Hash

N/A

## Remaining Work

- Perform installed-host runtime validation later with real game and sidecar processes if the workflow advances to runtime testing.
