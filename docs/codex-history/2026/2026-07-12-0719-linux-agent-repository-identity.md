# Task

## User Request

Workflow ID: `gse-repository-migration-20260712`, step `linux` 2 of 4. Verify assumptions first, work only in `/home/dev/Projects/GSP/GSP-Agent-Linux`, migrate repository identity from `GSP/GSP-Agent-Linux` to `GSE/Agent-Linux`, set origin to `ssh://git@173.208.136.14/GSE/Agent-Linux.git`, update browser/archive/release links and git commands to `https://git.runlevelsystems.com/GSE/Agent-Linux` as appropriate, update obsolete GSP/Gameserver Panel naming only where safe, retain and document protocol/config compatibility identifiers, validate, classify legacy references, commit, and push `unstable` only after verification passes.

## Problem

The Linux agent repository still carried the obsolete repository identity in Git remotes, installer defaults, restart-time update defaults, and operator documentation. User-facing names also still described the product as GSP/GameServer Panel in active scripts and docs.

## Root Cause

The repository migration to the canonical GSE organization had not been applied to the Linux agent. Runtime compatibility names such as `gsp_agent`, `/home/gameserver/GSP`, `gsp_` config keys, `GSP_*` screen names, `X-GSP-*` headers, and `GSP_WORKSHOP_*` markers were mixed with obsolete project identity text, so a blind rename would have risked breaking installed-agent and Panel compatibility.

## Repositories Inspected

- `/home/dev/Projects/GSP/GSP-Agent-Linux`

## Files Read

- `/home/dev/Projects/GSP/AGENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/AGENT_ACTIVITY_EVENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/agent-modernization-step-1-divergence-report.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install_agent_prereqs.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/systemd/gsp_agent.service`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/bash_prefs.cfg.default`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/Config.pm.default`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/includes/gsp_agent.init`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/includes/gsp_agent.init.rh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/includes/gsp_agent.init.gentoo`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/includes/gsp_agent.init.dbn`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/EHCP/addAccount.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/EHCP/config.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/EHCP/updatePass.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/db/php_aggregator.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/resource_usage_test.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/DEVELOPMENT`

## Files Changed

- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/bash_prefs.cfg.default`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/DEVELOPMENT`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/EHCP/addAccount.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/EHCP/config.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/EHCP/updatePass.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/db/php_aggregator.php`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/AGENT_ACTIVITY_EVENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/includes/gsp_agent.init`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/includes/gsp_agent.init.dbn`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/includes/gsp_agent.init.gentoo`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/includes/gsp_agent.init.rh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install_agent_prereqs.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/resource_usage_test.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/systemd/gsp_agent.service`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-12-0719-linux-agent-repository-identity.md`

## Architecture Decisions

- Verified the gate assumptions before editing: the repo was clean on `unstable`, tracked the obsolete `GSP/GSP-Agent-Linux` origin, and active install/update defaults referenced the obsolete repository.
- Changed installer and restart-time update defaults to `https://git.runlevelsystems.com/GSE/Agent-Linux` for customer-facing Git clone/update flows.
- Updated user-facing product naming from GSP/GameServer Panel to GSE/Gameserver Engine where it did not affect compatibility.
- Retained installed-agent compatibility identifiers: `gsp_agent` script/service names, `/home/gameserver/GSP`, `gsp_` config keys and table prefixes, `GSP_*` screen/session names, `{GSP_*}` command variables, `X-GSP-*` event headers, `GSP_WORKSHOP_*` markers, module namespace `Frontier::Daemon::GSP::Forking`, and historical codex/divergence report text.
- Did not rename the active local directory because the workflow was executing inside `/home/dev/Projects/GSP/GSP-Agent-Linux`; the safe post-task command is `cd /home/dev/Projects/GSP && mv GSP-Agent-Linux Agent-Linux`.

## Validation Performed

- `git status --short --branch`
- `git diff`
- `git diff --check`
- `bash -n install.sh agent_conf.sh gsp_agent_run install_agent_prereqs.sh includes/gsp_agent.init includes/gsp_agent.init.rh includes/gsp_agent.init.gentoo includes/gsp_agent.init.dbn`
- `perl -c gsp_agent.pl` passed with pre-existing `DBI::errstr` warning.
- `perl -c resource_usage_test.pl`
- `php -l EHCP/addAccount.php`
- `php -l EHCP/config.php`
- `php -l EHCP/updatePass.php`
- `php -l db/php_aggregator.php`
- `./install.sh --dry-run --non-interactive --no-prereqs --no-service`
- `git ls-remote --heads https://git.runlevelsystems.com/GSE/Agent-Linux unstable`
- Legacy-reference classification search confirmed active obsolete repository URL/name hits were removed; remaining obsolete `GSP-Agent-Linux`, `GSP-Agent-Windows`, and old `runlevelsystems.com` entries are historical in `docs/agent-modernization-step-1-divergence-report.md`.

## Git Commits

Repository

`GSP-Agent-Linux`

Commit

`Migrate Linux agent repository identity`

Hash

`a159362933db17261e85a9c2c62ef63f42d67423`

## Remaining Work

- Rename the local checkout directory outside this active session if desired: `cd /home/dev/Projects/GSP && mv GSP-Agent-Linux Agent-Linux`.
- Complete later workflow steps for the other repositories; this step intentionally changed only the Linux agent repository.
