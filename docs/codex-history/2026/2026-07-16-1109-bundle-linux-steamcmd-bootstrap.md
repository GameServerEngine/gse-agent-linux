# Task

## User Request

Bundle the downloaded Linux SteamCMD bootstrap into the GSE Linux agent release payload so offline installs include `steamcmd/steamcmd.sh`, while keeping SteamCMD optional for agent startup and non-Steam servers. Validate archive integrity, preserve existing SteamCMD runtime state, update installer/payload validation, remove any startup SteamCMD dependency, update documentation/tests, commit with `feat: bundle Linux SteamCMD bootstrap`, and push when safe.

## Problem

The repository already contained the extracted Linux SteamCMD bootstrap files under `steamcmd/`, but install, repair, and restart-time update copy paths excluded `steamcmd/` entirely. A fresh offline install from the repository payload could therefore miss `steamcmd/steamcmd.sh`. The Perl agent also checked SteamCMD during global startup, which made non-Steam startup depend on a Steam-specific runtime.

## Root Cause

SteamCMD was treated only as preserved runtime state. That protected installed SteamCMD data, but it also prevented source-owned bootstrap files from being restored into new or repaired installs. The legacy helper attempted a network download when SteamCMD was absent and was called during agent startup.

## Repositories Inspected

- `/home/dev/Projects/GSE-Agent-Linux`

## Files Read

- `AGENTS.md`
- `README.md`
- `documentation/agent-guide.md`
- `docs/PANEL_INTEGRATION.md`
- `docs/AGENT_ACTIVITY_EVENTS.md`
- `docs/plans/README.md`
- `docs/plans/ACTIVE.md`
- `docs/plans/BACKLOG.md`
- `docs/plans/lgsl-gameq-protocol-removal.md`
- existing `docs/codex-history/2026/*.md`
- `.devplus/codex-runs/FINAL_REPORT.md`
- `.devplus/codex-runs/latest/FINAL_REPORT.md`
- `install.sh`
- `gsp_agent.pl`
- `gsp_agent_run`
- `tests/validate_linux_agent_contract.sh`
- `steamcmd_linux.tar.gz`
- `steamcmd/steamcmd.sh`
- `steamcmd/linux32/steamcmd`
- `steamcmd/linux32/steamerrorreporter`
- `steamcmd/linux32/libstdc++.so.6`
- `steamcmd/linux32/crashhandler.so`

## Files Changed

- `.gitignore`
- `README.md`
- `documentation/agent-guide.md`
- `docs/PANEL_INTEGRATION.md`
- `docs/codex-history/2026/2026-07-16-1109-bundle-linux-steamcmd-bootstrap.md`
- `gsp_agent.pl`
- `gsp_agent_run`
- `install.sh`
- `steamcmd/steamcmd.sh`
- `steamcmd/linux32/steamcmd`
- `steamcmd/linux32/steamerrorreporter`
- `steamcmd/linux32/libstdc++.so.6`
- `steamcmd/linux32/crashhandler.so`
- `tests/validate_linux_agent_contract.sh`
- `tests/validate_steamcmd_bootstrap_payload.sh`

## Architecture Decisions

- Use the extracted `steamcmd/` bootstrap files as the durable release payload because `steamcmd_linux.tar.gz` contains exactly `steamcmd.sh` and `linux32/*`, and those files match the existing tracked tree byte-for-byte.
- Do not commit the repository-root `steamcmd_linux.tar.gz`; it was an input artifact and is ignored after validation.
- Keep `steamcmd/` excluded from bulk backup/copy operations so installed runtime state, `steamapps/`, credentials, logs, cache, and self-updated files are preserved.
- Add explicit missing-file restoration for the five bundled bootstrap files during install, repair, restart-time update, and component update paths.
- Validate staged and installed Linux payloads for the SteamCMD bootstrap and executable bits.
- Remove the global startup call to `check_steam_cmd_client()`.
- Keep Steam-specific operations calling the SteamCMD helper at operation time and return Steam-specific failures when the bootstrap is unavailable.
- Remove the legacy network download behavior from the helper; documentation and helper output reference the HTTPS SteamCMD download URL only for manual recovery.

## Validation Performed

- Confirmed branch `unstable`, upstream `origin/unstable`, and remote `ssh://git@173.208.136.14/GSE/Agent-Linux.git`.
- Confirmed pre-existing Git state had no tracked/staged diffs and only unrelated untracked DEV+1 files plus the input archive/instruction files.
- Verified `steamcmd_linux.tar.gz` exists, size `2428561` bytes, is gzip-compressed, passes `gzip -t`, and contains only `steamcmd.sh`, `linux32/steamcmd`, `linux32/steamerrorreporter`, `linux32/libstdc++.so.6`, and `linux32/crashhandler.so`.
- Extracted the archive to a temporary directory and confirmed each archive file matches the tracked `steamcmd/` file byte-for-byte.
- Confirmed no Windows SteamCMD files, `steamapps`, logs, credentials, or generated SteamCMD state are present under `steamcmd/`.
- `bash -n install.sh install_agent_prereqs.sh agent_conf.sh gsp_agent_run tests/validate_linux_agent_contract.sh tests/validate_steamcmd_bootstrap_payload.sh`
- `perl -c gsp_agent.pl` passed with the pre-existing `DBI::errstr` warning.
- `tests/validate_steamcmd_bootstrap_payload.sh`
- `tests/validate_linux_agent_contract.sh`
- Installer copy simulation confirmed existing `steamcmd/steamcmd.sh`, existing `steamcmd/linux32/steamcmd`, and `steamcmd/steamapps/customer.txt` are preserved while missing bootstrap files are restored.
- Restart-time updater copy simulation confirmed the same preservation and restoration behavior.
- `git diff --check`

## Git Commits

Repository

`/home/dev/Projects/GSE-Agent-Linux`

Commit

`feat: bundle Linux SteamCMD bootstrap`

Hash

Pending commit creation.

## Remaining Work

- Run a full root install, repair, service restart, and Steam-specific operation on a disposable Debian/Ubuntu host. This local validation did not mutate host systemd services or run SteamCMD against the network.
