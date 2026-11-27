# Task
Stop the release update from leaving the old agent code running (Linux agent).

## User Request
"Fix the helper issues" (after the update of game5 and game6 reported success while the agents still ran 1.8.0).

## Problem
After a release update the panel showed "Agent updated to testing-1.8.2 and running" but the agent still reported the old version.

## Root Cause
agent_update_helper.sh stopped only the perl agent with kill -TERM. agent_core_run treats a non-zero exit as a crash and starts the agent again after 10 seconds, which landed in the middle of the file copy (game5: restarted 20:56:55, copy finished 20:56:59; game6: 21:01:57 and 21:02:07). The helper's "agent is running" check was satisfied by that old process.

## Repositories Inspected
gse-agent-linux (changed). gse-agent-windows (read only, for the matching Windows defect).

## Files Read
agent_update_helper.sh, agent_core_run, agent_core.pl (start_agent_update), systemd/agent_core.service, the helper logs and update state on game5, game6 and the demo agent.

## Files Changed
agent_core_run, agent_update_helper.sh, tests/validate_update_helper_race.sh (new), CHANGELOG.md, docs/PANEL_INTEGRATION.md, docs/TODO.md.

## Architecture Decisions
- Do not stop the supervisor: under systemd (the demo agent) it is the unit's main process (Restart=on-failure), and the helper runs inside the unit's control group. Stopping the supervisor would end the unit and kill the helper mid-update.
- Instead the helper creates agent_update_hold and agent_core_run waits on it before every start of the agent. A hold older than 15 minutes is ignored so a dead helper cannot keep the agent down.
- The helper also verifies the result: after the copy it checks that every agent process started after the copy and restarts any that did not, up to two times. This covers hosts whose supervisor predates the hold. It reports ok only when the running agent is new.
- The fix cannot protect the update that installs it: the helper and supervisor that run an update are the installed ones.
- Test timings can be shortened with GSE_UPDATE_SETTLE_SECONDS, GSE_UPDATE_POLL_SECONDS and GSE_UPDATE_STABLE_SECONDS; the defaults are unchanged.

## Validation Performed
tests/validate_update_helper_race.sh: fake agent that logs the code version it loaded, a cp that is slowed so the restart lands inside the copy, five scenarios. Against the old helper the update reported ok while the agent had loaded the old code (reproduced first). With the fix all five pass: a supervisor without the hold is repaired by the helper's check; a supervisor with the hold starts the agent exactly twice (before and after) with no restart during the copy; a wrong checksum leaves no hold and the agent comes back; an old hold is ignored; a fresh hold blocks a restart and releasing it allows one.
The test signals every process matching perl.*agent_core.pl, so it refuses to run where a real agent is visible and was run in a PID namespace (sudo unshare --pid --fork --mount-proc).
All other tests in the repository give the same result with and without the change.

## Git Commits
See git log on working in gse-agent-linux.

## Remaining Work
Install the build with the fix on game5, game6 and the demo agent (T-038).
