# Active Plans

## LGSL/GameQ/protocol-removal

- Status: Active linked plan; Linux agent scope is verification/planning only until a future implementation task requires code changes.
- Owner repository: `/home/dev/Projects/GSE-Panel`
- Related repositories: `/home/dev/Projects/GSE-Agent-Linux`, `/home/dev/Projects/GSE-Agent-Windows`
- Next action: Verify Linux `server_status`/heartbeat semantics and inventory any `remote_query`, LGSL, GameQ, query, player, or map dependencies before Panel query removal.
- Stop condition: Stop before code changes if agent-side removal would affect `server_status`, lifecycle status, start/stop/restart/force-stop behavior, logs, console, scheduler, or Panel compatibility.
- Detailed plan: `/home/dev/Projects/GSE-Panel/docs/plans/lgsl-gameq-protocol-removal/PLAN.md`
- Local scope: `docs/plans/lgsl-gameq-protocol-removal.md`
