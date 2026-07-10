# Task

## User Request

Workflow `gsp-agent-modernization`, step 5 of 5: verify all changes from steps 1-4 across Linux and Windows agents, validate clean install/config/service/manual foreground/startup guard/queued update behavior, confirm Windows service and batch responsibility boundaries, confirm repos are clean, documented, committed, and pushed on `unstable`, add concise operator docs, run all available checks, and report platform limits. Do not introduce new features; verification and minimal corrective fixes only.

## Problem

The workflow needed a final verification gate to confirm that the Linux and Windows modernization work was internally consistent and documented before marking the modernization sequence passed.

## Root Cause

Steps 1-4 intentionally changed installer, startup, service, foreground, duplicate-guard, and queued update behavior. A final pass was required because the behavior spans repository boundaries and cannot be fully inferred from individual step commits.

## Repositories Inspected

- `/home/dev/Projects/GSP/GSP-Agent-Linux`
- `/home/dev/Projects/GSP/GSP-Agent-Windows`
- `/home/dev/Projects/GSP/Panel`
- `/home/dev/Projects/GSP/references/OGP`

## Files Read

- `/home/dev/Projects/GSP/AGENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/agent-modernization-step-1-divergence-report.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1055-agent-modernization-step-1.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1257-linux-installer-modernization.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1336-queued-agent-update.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/systemd/gsp_agent.service`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/AGENT_ARCHITECTURE.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/CYGWIN_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/COMMAND_EXECUTION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PROCESS_MANAGEMENT.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/GSP_WINDOWS_AGENT_PORT_VALIDATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/agent-modernization-step-1-divergence-report.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/codex-history/2026/2026-07-10-1055-agent-modernization-step-1.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/codex-history/2026/2026-07-10-1317-modernize-windows-root-service.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/codex-history/2026/2026-07-10-1336-queued-agent-update.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/agent_launch.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/Install-GSP-WindowsAgent.ps1`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/agent_start.bat`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/agent_stop.bat`
- `/home/dev/Projects/GSP/Panel/README.md`
- `/home/dev/Projects/GSP/Panel/docs/ARCHITECTURE.md`
- `/home/dev/Projects/GSP/Panel/docs/AGENT_COMMUNICATION.md`
- `/home/dev/Projects/GSP/Panel/docs/COMMAND_FLOW.md`
- `/home/dev/Projects/GSP/Panel/docs/UPDATE_POLICY.md`

## Files Changed

- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1345-agent-modernization-step-5.md`

## Architecture Decisions

- Keep Linux service and foreground execution on the same `gsp_agent_run` wrapper.
- Keep restart-time updates as wrapper-owned behavior triggered only by a queued `agent_self_update` request and `agent_auto_update=1`.
- Keep systemd as the production lifecycle owner for Linux.
- Do not add runtime features during this step; documentation was updated to clarify existing behavior.

## Validation Performed

- `git status`, `git diff`, and recent `git log` review across Linux, Windows, and Panel repositories.
- Reviewed step 1-4 history records and current launcher/installer/service code.
- `bash -n install.sh install_agent_prereqs.sh agent_conf.sh gsp_agent_run`
- `perl -c gsp_agent.pl`
- `perl -c resource_usage_test.pl`
- Generated temporary config with `agent_conf.sh` and loaded it through Perl.
- Ran installer dry-run with noninteractive, no-prereq, no-service options.
- Verified substituted systemd unit with `systemd-analyze verify` against a temporary executable path.
- Simulated queued update disabled, queued update success, and bad update rollback in a temporary Linux install.
- Simulated duplicate wrapper startup refusal.
- Simulated configured agent port refusal.
- `git diff --check`

## Git Commits

Repository

`GSP-Agent-Linux`

Commit

`Document agent modernization workflows`

Hash

Assigned after this history record is committed; see final task report.

## Remaining Work

- Full clean install and real `systemctl enable/start/restart` validation must be performed on a Debian/Ubuntu host with the intended service user and network/firewall setup.
