# Task
Stop the Linux update helper from breaking when an update replaces the helper itself.

## User Request
"Fix the helper issues": after the race fix, a third defect was found in the demo agent's update log (every stage logged twice).

## Problem
agent_update_helper.sh is one of the files an update replaces, and it replaces itself while running. The demo agent's update on 2026-11-26 logged "Agent stopped", "Checksum verified" and "Backup written" twice. It finished, but only because of the particular size of that change.

## Root Cause
Bash reads a script from the file as it goes. The helper copies the new files with cp -f, which rewrites the same file in place, so after the copy loop bash resumed reading the NEW file at the OLD byte offset. Where it resumes depends on how far the new text moved, so the effect ranges from repeated steps to a helper that dies half way.

## Repositories Inspected
gse-agent-linux (changed). gse-agent-windows has the same helper design (fixed in its own record).

## Files Read
agent_update_helper.sh, the helper log on the demo agent, tests/validate_update_helper_race.sh.

## Files Changed
agent_update_helper.sh (the whole sequence is now the function main, called on the last line), tests/validate_update_helper_race.sh (scenario S6), CHANGELOG.md, docs/PANEL_INTEGRATION.md, docs/TODO.md.

## Architecture Decisions
- Put everything after the argument handling in one function and call it as `main "$@"; exit $?` on the last line. Bash must read a function definition completely before it runs it, and the last line is one command list, so nothing is read from the file after the files are replaced.
- Rejected: copying the helper to a temp file and re-running it from there (more moving parts, a stray file when it fails) and replacing files by rename (it would not protect the helper that is already installed, which still uses cp).
- The fix cannot protect an update run by an already installed helper. For the rollout the new helper file is placed on each host first (copy beside it, check the SHA-256, rename over it) so the update itself runs the fixed helper.

## Validation Performed
Scenario S6 ships a helper with 5, 40, 120 and 250 extra lines near the top, runs the installed copy, and checks the result, that every stage ran exactly once, and that the helper printed no shell errors. Against the helper before this change it failed at all four sizes (stalled or failed at 5, 40 and 250; ran every step twice at 120). With the fix all four pass, and S1 to S5 still pass. validate_linux_agent_contract.sh and validate_requirements.sh pass. The test signals every process matching perl.*agent_core.pl, so it refuses to run where a real agent is visible and was run in a PID namespace.

## Git Commits
See git log on working in gse-agent-linux.

## Remaining Work
Install the build with the fixes on game5, game6 and the demo agent (T-038); the order and the helper placement are in docs/TODO.md.
