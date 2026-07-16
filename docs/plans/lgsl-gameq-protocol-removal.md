# LGSL/GameQ/protocol-removal Linux Agent Scope

Primary plan owner: `/home/dev/Projects/GSE-Panel`

Detailed plan: `/home/dev/Projects/GSE-Panel/docs/plans/lgsl-gameq-protocol-removal/PLAN.md`

## Local Responsibilities

- Inventory Linux agent references to LGSL, GameQ, `remote_query`, query protocol, query ports, player/map metadata, heartbeat/status, and lifecycle controls.
- Verify `gsp_agent.pl` `server_status` remains the authoritative lifecycle/status signal for the Panel.
- Confirm `server_status` reports process/session/port readiness without requiring LGSL/GameQ query success.
- Ensure no agent-side removal breaks Panel Start, Stop, Restart, Force Stop, logs, console, scheduler, or file/config operations.
- Document whether no Linux code changes are expected.

## Initial Findings

- `gsp_agent.pl` exposes `server_status` and returns structured readiness fields used by the Panel.
- `gsp_agent.pl` also exposes `remote_query`, which shells through bundled `php-query/lgsl/` and `php-query/gameq/` scripts.
- `docs/PANEL_INTEGRATION.md` and `documentation/agent-guide.md` already document `server_status` as the shared readiness contract.
- `KKrcon/` contains RCON player helpers; this is unrelated and must not be removed as LGSL/GameQ cleanup.

## Expected Code Impact

No Linux agent code changes are expected unless the future Panel implementation still calls `remote_query` or a product decision is made to remove/deactivate the agent-side query RPC and bundled query scripts.
