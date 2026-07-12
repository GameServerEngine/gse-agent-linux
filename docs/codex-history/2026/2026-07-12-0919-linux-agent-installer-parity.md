# Task

## User Request

Verification gate and implementation for Linux agent parity: inspect Linux and Windows agent repositories first, edit only `/home/dev/Projects/GSP/GSP-Agent-Linux` on branch `unstable`, confirm canonical Linux identity `GSE/Agent-Linux`, compare Windows `GSP/gse_agent.pl` and installer flow against Linux `gsp_agent.pl` and installer scripts, port only clearly shared verified behavior, preserve Linux-native runtime semantics, align the Linux installer with install/repair/reconfigure/uninstall lifecycle using canonical `https://git.runlevelsystems.com/GSE/Agent-Linux` and `unstable`, add focused tests and docs, validate thoroughly, commit and push only after validation passes.

## Problem

The Linux Perl agent and installer were close to the modernized behavior but still diverged from the verified Windows-side contract in two safe shared areas:

- `server_status` did not expose the Windows-aligned port-validation metadata and resource keys now expected as a shared Panel-facing response contract.
- `install.sh` did not implement a real uninstall mode and only performed minimal staged payload validation before copying fetched source.

## Root Cause

The two Perl agents evolved separately. Recent Linux modernization restored Git-based install, repair, reconfigure, and restart-time update behavior, while recent Windows modernization verified a stricter installer lifecycle and status contract. The Linux installer predated the now-verified four-mode Windows installer UX and validation model, and the Linux status response had not yet been updated with the shared Windows-facing metadata keys.

## Repositories Inspected

- `/home/dev/Projects/GSP/GSP-Agent-Linux`
- `/home/dev/Projects/GSP/GSP-Agent-Windows`

## Files Read

- `/home/dev/Projects/GSP/AGENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/AGENT_ACTIVITY_EVENTS.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/agent-modernization-step-1-divergence-report.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1257-linux-installer-modernization.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-10-1345-agent-modernization-step-5.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-11-0005-agent-lifecycle-parity.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-12-0719-linux-agent-repository-identity.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install_agent_prereqs.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/systemd/gsp_agent.service`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/Cfg/bash_prefs.cfg.default`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/GSP/gse_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/Installer-Agent-Windows.cmd`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/Installer-Agent-Windows.ps1`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/tests/validate_offline_installer_contract.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/tests/validate_default_archive_payload.sh`

## Files Changed

- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/README.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/tests/validate_linux_agent_contract.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/codex-history/2026/2026-07-12-0919-linux-agent-installer-parity.md`

## Architecture Decisions

- Keep Linux `agent_self_update` and restart-time update Git repo/branch/source semantics; do not copy Windows release patch metadata handling into Linux without a separate release-artifact design.
- Keep Linux-native process, port, user, permission, `screen`, `systemd`, shell quoting, and filesystem behavior.
- Add shared `server_status` response metadata fields while retaining Linux `linux_pid` and existing compatibility aliases.
- Add installer `uninstall` mode without cloning or copying payloads.
- Preserve customer/runtime state by default during uninstall; make full install-directory removal require explicit `--purge-data`.
- Validate staged and installed Linux payloads before replacement/service start using Linux-native `perl -c` and `bash -n`.
- Keep `install.sh` as the canonical Linux installer name.

## Validation Performed

- Confirmed Linux repository identity: branch `unstable`, tracking `origin/unstable`, origin `ssh://git@173.208.136.14/GSE/Agent-Linux.git`, clean before edits.
- Confirmed Windows reference repository on `unstable`, tracking `origin/unstable`, origin `ssh://git@173.208.136.14/GSE/Agent-Windows.git`; untracked Windows Cygwin/package/history files were ignored as read-only reference state.
- Reviewed recent commits, status, diff, and origin for both Linux and Windows agent repositories.
- Performed subroutine-level Linux/Windows comparison before and after edits.
- Classified remaining Windows-only Perl differences as Cygwin/PowerShell/Windows process helpers or Windows release-patch update handling.
- Classified remaining Linux-only Perl differences as Linux metrics/resource stats, DB stats, Linux user/permission helpers, and Linux process helpers.
- `perl -c gsp_agent.pl` passed with the pre-existing `DBI::errstr` warning.
- `perl -c resource_usage_test.pl` passed.
- `bash -n install.sh install_agent_prereqs.sh agent_conf.sh gsp_agent_run tests/validate_linux_agent_contract.sh` passed.
- `tests/validate_linux_agent_contract.sh` passed.
- Dry-run simulations passed for `install`, `repair`, `reconfigure`, and `uninstall`.
- Function-level staged payload validation passed for the current Linux source tree.
- Function-level uninstall preservation validation passed: managed files were removed while `Cfg/` and `logs/` customer files remained.
- systemd unit template substitution was verified through the focused contract test with `systemd-analyze verify`.
- `git ls-remote --heads https://git.runlevelsystems.com/GSE/Agent-Linux unstable` resolved the canonical branch.
- Active-file search found no stale `GSP-Agent-Linux`, old OpenGamePanel/GSP Linux repository URLs, old forge URL, `Panel-unstable`, or Windows-only command strings outside historical records.
- `git diff --check` passed.

Skipped:

- A real root install/repair/reconfigure/uninstall against `/home/gameserver/GSP` and active `systemctl` service mutation was not performed because this session is not a disposable Linux host with root service-management approval. The installer dry-runs and function-level validations exercised the safe parts without altering host services.

## Git Commits

Repository

`GSP-Agent-Linux`

Commit

`Align Linux agent and installer behavior`

Hash

Assigned by the commit containing this record; see the final task report for the exact pushed hash.

## Remaining Work

- Validate a full root install, repair, reconfigure, uninstall, and service start/stop cycle on a disposable Debian/Ubuntu host with the intended `gameserver` user and firewall/network setup.
