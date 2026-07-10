# Task

## User Request

Workflow `gsp-agent-modernization`, step 2 of 5: verify the current Linux installer/update/startup root cause against step 1's OGP baseline, then build a reliable Debian/Ubuntu-first interactive Linux installer, Git-based install/update flow, systemd service setup, restart-time update restoration, single-instance startup protection, and repair/reconfigure modes. Validate the implementation, commit, and push verified work to `origin/unstable`. Stop with failure if OGP-compatible configuration cannot be produced without guessing business rules.

## Problem

The Linux installer and startup path exposed update settings but did not use them consistently. The installer copied from the local working tree instead of cloning the configured source repo/branch, `agent_conf.sh` hard-coded stale update source values, and `gsp_agent_run` had no restart-time update path or port-aware duplicate-start protection.

## Root Cause

GSP Linux had diverged from the verified OGP Linux baseline without replacing OGP's wrapper-owned restart-time update behavior. The current direct systemd service model was coherent, but the canonical wrapper only validated config and restarted `gsp_agent.pl`; it ignored `Cfg/bash_prefs.cfg` update settings and allowed duplicate startup attempts to proceed until the Perl service or port bind failed.

## Repositories Inspected

- `/home/dev/Projects/GSP/GSP-Agent-Linux`
- `/home/dev/Projects/GSP/GSP-Agent-Windows`
- `/home/dev/Projects/GSP/Panel`
- `/home/dev/Projects/GSP/references/OGP`

## Files Read

- `/home/dev/Projects/GSP/AGENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/agent-modernization-step-1-divergence-report.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1055-agent-modernization-step-1.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install_agent_prereqs.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/systemd/gsp_agent.service`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/Config.pm.default`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/Preferences.pm.default`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/bash_prefs.cfg.default`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/AGENT_ARCHITECTURE.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/COMMAND_EXECUTION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PROCESS_MANAGEMENT.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/Panel/README.md`
- `/home/dev/Projects/GSP/Panel/docs/ARCHITECTURE.md`
- `/home/dev/Projects/GSP/Panel/docs/PANEL_ARCHITECTURE.md`
- `/home/dev/Projects/GSP/Panel/docs/AGENT_COMMUNICATION.md`
- `/home/dev/Projects/GSP/Panel/docs/REPOSITORY_STRUCTURE.md`
- `/home/dev/Projects/GSP/Panel/docs/COMMAND_FLOW.md`
- `/home/dev/Projects/GSP/Panel/docs/UPDATE_POLICY.md`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/ogp_agent_run`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/systemd/ogp_agent.service`
- `/home/dev/Projects/GSP/references/OGP/OGP-Install-Easily-Guide-Source/web_src/agent.html`
- `/home/dev/Projects/GSP/references/OGP/OGP-Website.wiki/Home.md`

## Files Changed

- `/home/dev/Projects/GSP/GSP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/bash_prefs.cfg.default`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1257-linux-installer-modernization.md`

## Architecture Decisions

- Keep the GSP direct systemd service model instead of reverting to OGP's SysV-plus-oneshot service.
- Keep `gsp_agent_run` as the single canonical service and foreground wrapper.
- Keep Panel-triggered `agent_self_update` intact and add restart-time update as local wrapper behavior only.
- Use `agent_update_repo_url`, `agent_update_branch`, and `agent_update_source_path` as the restart-time update contract.
- Preserve OGP-compatible `Config.pm`, `Preferences.pm`, and `bash_prefs.cfg` generation while adding only GSP settings currently consumed by the Linux agent/wrapper.
- Preserve runtime/customer data and local config during install repair and restart-time update.
- Refuse duplicate startup through a wrapper lock, valid PID state, and configured-port bind check without killing unrelated processes.

## Validation Performed

- `bash -n install.sh install_agent_prereqs.sh agent_conf.sh gsp_agent_run`
- `shellcheck install.sh install_agent_prereqs.sh agent_conf.sh gsp_agent_run` was skipped because `shellcheck` is not installed in this environment.
- `perl -c gsp_agent.pl`
- `perl -c resource_usage_test.pl`
- Generated temp config with `agent_conf.sh` and loaded it through `perl -I <temp> -MCfg::Config -MCfg::Preferences`.
- Verified generated `Cfg/bash_prefs.cfg` with `bash -n`.
- Verified a substituted systemd unit with `systemd-analyze verify`.
- Ran installer dry-run: `./install.sh --dry-run --non-interactive --no-prereqs --no-service ...`.
- Simulated restart-time update success with a temporary local Git repo and fake agent.
- Simulated restart-time update syntax failure and confirmed failure-loop prevention for the same revision.
- Simulated post-update startup failure and confirmed rollback to the previous fake agent.
- Simulated duplicate wrapper startup and confirmed the second wrapper exits without killing the first.
- Simulated an unrelated process listening on the configured agent port and confirmed wrapper startup is refused without killing that process.
- `git diff --check`

## Git Commits

Repository

`GSP-Agent-Linux`

Commit

`Modernize Linux agent installer`

Hash

`285cf21`

## Remaining Work

- `shellcheck` should be run in an environment where it is installed.
- Later workflow steps should address Windows launcher/update consolidation and any downstream Panel wrapper gaps identified in step 1.
