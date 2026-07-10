# Task

## User Request

Complete workflow `gsp-agent-modernization`, step 4 of 5. Implement consistent queued update request format/state for both agents using original OGP update-on-restart semantics as baseline. Running agents must only record pending update requests; startup wrappers apply pending updates on the next normal restart when enabled, preserve config/runtime/customer data, expose pending/running/completed/failed/rolled-back status, validate and roll back safely, and commit/push verified work to `origin/unstable`.

## Problem

The Linux agent still had a detached self-update path that could replace files while the agent was running. Restart-time update state used `succeeded`/`in_progress` instead of the required shared state contract and did not require a queued request.

## Root Cause

The existing Linux implementation combined two models: OGP-style update-on-wrapper-start and a newer detached `agent_self_update` script. The detached script violated the desired no-self-overwrite model, and the wrapper could check the configured branch without an explicit pending request.

## Repositories Inspected

- `/home/dev/Projects/GSP/Panel`
- `/home/dev/Projects/GSP/GSP-Agent-Linux`
- `/home/dev/Projects/GSP/GSP-Agent-Windows`
- `/home/dev/Projects/GSP/references/OGP`

## Files Read

- `/home/dev/Projects/GSP/AGENTS.md`
- `/home/dev/Projects/GSP/Panel/README.md`
- `/home/dev/Projects/GSP/Panel/docs/ARCHITECTURE.md`
- `/home/dev/Projects/GSP/Panel/docs/PANEL_ARCHITECTURE.md`
- `/home/dev/Projects/GSP/Panel/docs/AGENT_COMMUNICATION.md`
- `/home/dev/Projects/GSP/Panel/docs/COMMAND_FLOW.md`
- `/home/dev/Projects/GSP/Panel/docs/UPDATE_POLICY.md`
- `/home/dev/Projects/GSP/Panel/docs/architecture/PANEL_AGENT_COMMANDS.md`
- `/home/dev/Projects/GSP/Panel/docs/architecture/PANEL_AGENT_FLOW.md`
- `/home/dev/Projects/GSP/Panel/includes/lib_remote.php`
- `/home/dev/Projects/GSP/Panel/modules/server/agent_helpers.php`
- `/home/dev/Projects/GSP/Panel/modules/server/agent_interface.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/bash_prefs.cfg.default`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/AGENT_ARCHITECTURE.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/CYGWIN_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/COMMAND_EXECUTION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PROCESS_MANAGEMENT.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/agent_launch.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/gsp_agent.pl`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/ogp_agent_run`

## Files Changed

- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`

## Architecture Decisions

- Preserve the existing XML-RPC command name `agent_self_update`; change its behavior to queue a pending restart-time request instead of launching a detached self-replacer.
- Add `gsp_agent_update_request.json` as the durable pending request and keep `gsp_agent_update_state.json` as the panel-readable status file.
- Use the shared states `pending`, `running`, `completed`, `failed`, and `rolled_back`.
- Require `agent_auto_update=1` before a startup wrapper applies a pending request.
- Remove pending requests after terminal success, failure, or rollback so failed requests do not repeat every restart.
- Preserve config, runtime state, secrets, customer data, logs, and PID files during backup/copy/rollback.

## Validation Performed

- `bash -n gsp_agent_run`
- `perl -c gsp_agent.pl`
- `git diff --check`
- Temporary Linux wrapper simulation:
  - pending request success -> `completed`, request removed
  - staged validation failure -> `failed`, request removed
  - update disabled -> `pending`, request retained
  - post-copy validation failure -> `rolled_back`, request removed, previous file restored
- Verified no detached updater script is launched by `agent_self_update`.
- Verified no retry loop because terminal paths remove `gsp_agent_update_request.json`.

## Git Commits

Repository

`GSP-Agent-Linux`

Commit

`Queue agent updates for restart startup`

Hash

`5686e0da267f18a0a1099dd3982e55c79d41d405`

## Remaining Work

- Full service-level restart testing should be performed on an installed Linux host with systemd.
