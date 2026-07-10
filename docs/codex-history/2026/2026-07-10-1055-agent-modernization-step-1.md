# Task

## User Request

Workflow `gsp-agent-modernization`, step 1 of 5: verify original Open Game Panel Linux and Windows agent behavior, inspect current GSP Linux and Windows agent repositories plus downstream Panel logic, identify divergences, and produce a precise report and recommended target architecture. Do not edit runtime or installer implementation in this step. Commit and push a verified report only if complete.

## Problem

The GSP Linux and Windows agents contain custom installers, launchers, update helpers, and Panel-facing update commands. Their behavior needed to be verified against original OGP source and documentation before later modernization steps change runtime code.

## Root Cause

The current agents are no longer direct OGP copies. Linux has moved to a split-repository, direct systemd, Panel-driven update model. Windows has accumulated duplicated launchers and updater scripts with conflicting repository, branch, service-account, and runtime-layout assumptions. Original OGP Linux restart-time update behavior also differed materially from current GSP defaults.

## Repositories Inspected

- `/home/dev/Projects/GSP/GSP-Agent-Linux`
- `/home/dev/Projects/GSP/GSP-Agent-Windows`
- `/home/dev/Projects/GSP/Panel`
- `/home/dev/Projects/GSP/gsp-website`
- `/home/dev/Projects/GSP/Panel.wiki`
- `/home/dev/Projects/GSP/references/OGP`

## Files Read

- `/home/dev/Projects/GSP/AGENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install_agent_prereqs.sh`
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
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/WINDOWS_AGENT_UPDATE_BAT.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP64/agent_start.bat`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP64/agent_stop.bat`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP64/agent_update.bat`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP64/GSP/Install/agent_start.bat`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP64/GSP/Install/agent_start_cygwin.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP64/GSP/Cfg/bash_prefs.cfg.default`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP64/GSP/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/bin/gsp_agent`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/Installer/README-FIRST.txt`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/Installer/Install-GSP-WindowsAgent.ps1`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/Installer/Configure-GSP-WindowsAgent.ps1`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/Installer/Update-GSP-WindowsAgent.ps1`
- `/home/dev/Projects/GSP/Panel/includes/lib_remote.php`
- `/home/dev/Projects/GSP/Panel/modules/server/agent_interface.php`
- `/home/dev/Projects/GSP/Panel/modules/server/restart.php`
- `/home/dev/Projects/GSP/Panel/modules/server/agent_helpers.php`
- `/home/dev/Projects/GSP/Panel/docs/architecture/PANEL_AGENT_COMMANDS.md`
- `/home/dev/Projects/GSP/Panel/docs/features/INSTALLERS.md`
- `/home/dev/Projects/GSP/Panel/docs/agents/WINDOWS_AGENT.md`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/ogp_agent_run`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/systemd/ogp_agent.service`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/agent_conf.sh`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/ogp_agent.pl`
- `/home/dev/Projects/GSP/references/OGP/OGP-Install-Easily-Guide-Source/web_src/agent.html`
- `/home/dev/Projects/GSP/references/OGP/OGP-Website.wiki/Home.md`
- `/home/dev/Projects/GSP/references/OGP/Easy-Installers/README.md`
- `/home/dev/Projects/GSP/references/OGP/OGP-AIO-Update-Script/README.md`

## Files Changed

- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/agent-modernization-step-1-divergence-report.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1055-agent-modernization-step-1.md`

## Architecture Decisions

- Treat original OGP Linux `ogp_agent_run` as the verified restart-time update baseline.
- Treat original OGP Windows restart-time update as unverified in source; GSP Windows helpers are GSP-specific packaging unless matching Easy Installer source is verified.
- Recommend one canonical startup path per platform.
- Recommend keeping Panel-driven self-update as the primary admin-controlled update flow.
- Recommend explicitly restoring or removing restart-time update support instead of leaving unused config fields and stale helper scripts.

## Validation Performed

- Verified upstream OGP repository heads with `git ls-remote`.
- Checked current branch, status, diffs, and recent commits in both agent repositories.
- Compared OGP source, official docs, current GSP source, and downstream Panel wrappers/modules.
- Recorded exact file paths and startup/update execution flows in the divergence report.
- Ran `git diff --check` before commit.

## Git Commits

Repository

`GSP-Agent-Linux`

Commit

`Document agent modernization baseline`

Hash

Created with this history record; final hash is reported in the task final report.

## Remaining Work

- Implement no runtime changes in step 1.
- Later steps must choose and implement the canonical Linux restart-time update policy.
- Later steps must consolidate Windows startup/update/service-account behavior.
- Later steps should resolve missing Panel wrapper methods before relying on newer agent commands from the UI.
