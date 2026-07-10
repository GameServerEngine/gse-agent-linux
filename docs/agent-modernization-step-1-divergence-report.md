# Agent Modernization Step 1 Divergence Report

Workflow: `gsp-agent-modernization`

Step: `step-1`

Date: 2026-07-10

Status: PASSED

## Verification Gate

Original Open Game Panel source was verified before making this report.

Verified upstream repositories:

- `https://github.com/OpenGamePanel/OGP-Agent-Linux`, `master` at `fa8241548d5182de7e8cffbe7bf592ed16318130`
- `https://github.com/OpenGamePanel/OGP-Agent-Windows`, `master` at `7e7564c08468df3b42c232b6316bdb3a5faf3588`
- `https://github.com/OpenGamePanel/OGP-Install-Easily-Guide-Source`, `master` at `a20644ecaecf654e87e056a2c2e6201096492dc3`
- `https://github.com/OpenGamePanel/Easy-Installers`, `master` at `08e04d910241e9942703bc2eaaf1f5a8717bd639`

Verified local reference paths:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows`
- `/home/dev/Projects/GSP/references/OGP/OGP-Install-Easily-Guide-Source`
- `/home/dev/Projects/GSP/references/OGP/Easy-Installers`
- `/home/dev/Projects/GSP/references/OGP/OGP-Website.wiki`
- `/home/dev/Projects/GSP/references/OGP/OGP-AIO-Update-Script`

Official documentation sources checked:

- `https://www.opengamepanel.org/install_guide/agent.html`
- `https://sourceforge.net/p/hldstart/wiki/Installation%20Notes/`
- `/home/dev/Projects/GSP/references/OGP/OGP-Install-Easily-Guide-Source/web_src/agent.html`
- `/home/dev/Projects/GSP/references/OGP/OGP-Website.wiki/Home.md`
- `/home/dev/Projects/GSP/references/OGP/Easy-Installers/README.md`

Update-on-restart assumption check:

- OGP Linux implements restart-time auto-update in `ogp_agent_run` and defaults it on when `bash_prefs.cfg` is absent or when `agent_auto_update=1`.
- OGP Windows source exposes the same `agent_auto_update` config prompt, but the verified `OGP-Agent-Windows` source tree does not contain an equivalent launcher wrapper that implements restart-time updates.
- Current GSP Linux defaults `agent_auto_update=0` and `gsp_agent_run` does not implement restart-time update.
- Current GSP Windows has a stale helper that can update only `gsp_agent.pl`, but the root launcher does not call it.

This is not a workflow failure because the original behavior was verified and the divergence is now explicit. Later steps must not assume OGP and GSP already match here.

## Repositories Inspected

- `/home/dev/Projects/GSP/GSP-Agent-Linux`, branch `unstable`, clean before report generation
- `/home/dev/Projects/GSP/GSP-Agent-Windows`, branch `unstable`, clean before report generation
- `/home/dev/Projects/GSP/Panel`, branch `unstable`, dirty with unrelated local work; inspected only, not modified
- `/home/dev/Projects/GSP/gsp-website`, branch `unstable`, clean
- `/home/dev/Projects/GSP/Panel.wiki`, branch `main`, clean
- `/home/dev/Projects/GSP/references/OGP`, read-only reference material

Recent current-agent commits checked:

- Linux: `ce2559b Generate Linux watchdog startup script`, `470e1ed Add Linux agent code version and update config`, `ce7eb82 Accept legacy pidfile agent option`, `b286965 Update panel integration and agent self-update support`, `7665d70 cleanup`
- Windows: `48895de Generate Windows watchdog startup batch`, `3d32ba8 Accept pidfile and skip startup marker files`, `7ac70d6 Write Windows game PID from WMIC startup`, `143674f Revert Windows agent to July 2 stable runtime`, `47155dc Improve Windows status hint lifecycle`

## Original OGP Linux Baseline

### Prerequisites

Official install docs list distribution package prerequisites, including Perl modules, `screen`, `rsync`, `sudo`, `unzip`, `subversion`, `pure-ftpd`, archive libraries, 32-bit compatibility packages, `git`, and `curl`.

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Install-Easily-Guide-Source/web_src/agent.html`
- `/home/dev/Projects/GSP/references/OGP/OGP-Website.wiki/Home.md`
- Legacy SourceForge install notes documented Debian/Ubuntu dependencies and manual startup.

The original Linux installer also performs local command checks:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/install.sh:120` to `139` checks `screen`, `sed`, and warns for missing `rsync`.

### Configuration Generation

`agent_conf.sh` generates:

- `Cfg/Config.pm`
- `Cfg/Preferences.pm`
- `Cfg/bash_prefs.cfg`

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/agent_conf.sh:22` to `72` requires a Linux sudo password with `-s`.
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/agent_conf.sh:197` to `216` prompts for automatic update on service start or restart and defaults to yes.
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/agent_conf.sh:652` to `654` writes `agent_auto_update=${autoUpdate}`.

### Service Installation

Original OGP Linux service handling is a SysV wrapper plus a systemd oneshot unit.

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/install.sh:269` to `304` copies agent files and installs init/systemd wrappers.
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/install.sh:336` to `341` enables and restarts the service.
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/systemd/ogp_agent.service:8` to `16` uses `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart={OGP_AGENT_PATH}/ogp_agent_init start`, and `ExecStop={OGP_AGENT_PATH}/ogp_agent_init stop`.

### Foreground and Manual Startup

Legacy documentation starts the service with `/etc/init.d/ogp_agent start` or starts the agent manually with:

```sh
perl ./ogp_agent.pl --log-stdout
```

Evidence:

- `https://sourceforge.net/p/hldstart/wiki/Installation%20Notes/`

### Update On Restart

The original Linux restart-time update implementation lives in `ogp_agent_run`, not in `ogp_agent.pl`.

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/ogp_agent_run:1` to `18` defines wrapper state, `BASH_PREFS_CONF`, and `REPONAME=OGP-Agent-Linux`.
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/ogp_agent_run:141` to `160` defaults `AUTO_UPDATE=yes` when prefs are missing and enables it when `agent_auto_update=1`.
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/ogp_agent_run:208` to `297` downloads the latest master archive, self-relaunches if the wrapper changed, preserves existing preference files, copies code files, writes the upstream commit hash to `Config.pm`, and fixes permissions.
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/ogp_agent_run:300` to `318` obtains sudo password, restricts access, runs update, detects systemd, and starts the crash restart loop.

### Startup Guards

Original OGP Linux splits startup guards across wrapper and Perl agent:

- `ogp_agent_run` warns and delays when run as root but does not refuse to start.
- `ogp_agent.pl` performs startup directory creation, startup flag processing, and automatic server restart from startup markers.

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/ogp_agent_run:24` to `55`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/ogp_agent.pl:148` to `284` shows the shared OGP Perl startup-marker flow used by both platforms.

### Repository and Runtime Layout

Original OGP Linux installs code into an agent-owned runtime directory, defaulting to a user home path ending in `/OGP/`. The installer refuses unsafe install directories such as `/`, `/etc`, `/usr`, and `/var`.

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Linux/install.sh:195` to `220`

## Original OGP Windows Baseline

### Prerequisites and Installer Model

Official OGP Windows guidance says Windows agents must use Easy Installers with preconfigured Cygwin. It documents creation of a `cyg_server` administrator user, Windows x64 installer usage, automatic dependency installation, key length limits, firewall configuration, and avoiding `Program Files`.

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Install-Easily-Guide-Source/web_src/agent.html:250` to `263`
- `/home/dev/Projects/GSP/references/OGP/OGP-Website.wiki/Home.md`
- `/home/dev/Projects/GSP/references/OGP/Easy-Installers/README.md`

### Configuration Generation

The Windows source uses `OGP/agent_conf.sh` to generate the same config files as Linux, but it requires the Cygwin service account password with `-p`.

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/agent_conf.sh:22` to `72`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/agent_conf.sh:197` to `217` prompts for automatic update and defaults to yes.
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/agent_conf.sh:652` to `654` writes only `agent_auto_update=${autoUpdate}`.

### Service, Manual Startup, and Layout

The verified `OGP-Agent-Windows` source repository contains `OGP/` and `bin/ogp_agent`. The official service and batch packaging comes from the Windows Easy Installer distribution, not from a full source-side `GSP64` layout.

The official troubleshooting path is manual start and stop through Windows batch files:

- `agent_stop.bat`
- `agent_start.bat`

### Update On Restart

The verified Windows source has an update preference prompt but no verified source-side equivalent to Linux `ogp_agent_run`.

This matters for GSP: any Windows restart-time update helper must be treated as GSP-specific packaging unless a matching Easy Installer source is verified.

### Startup Guards

The original Windows Perl agent rejects UID 0, creates logs/shared/startup directories, validates SteamCMD, processes startup flags, and registers XML-RPC commands.

Evidence:

- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/ogp_agent.pl:106` to `113`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/ogp_agent.pl:148` to `284`
- `/home/dev/Projects/GSP/references/OGP/OGP-Agent-Windows/OGP/ogp_agent.pl:360` to `378`

## Current GSP Linux Findings

Current Linux files inspected:

- `/home/dev/Projects/GSP/GSP-Agent-Linux/install_agent_prereqs.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/install.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/agent_conf.sh`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent_run`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/systemd/gsp_agent.service`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/gsp_agent.pl`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Linux/documentation/agent-guide.md`

Divergences:

- `install_agent_prereqs.sh` is GSP-specific and only supports apt/dpkg families. It is not an OGP upstream script.
- `install.sh` is a GSP-specific installer. It defaults to user `gameserver`, install root `/home/gameserver/GSP`, runs `install_agent_prereqs.sh`, uses `rsync`, creates runtime directories, and installs a direct systemd service.
- `systemd/gsp_agent.service` is a direct `Type=simple` service that runs `gsp_agent_run` as `{GSP_AGENT_USER}`. This intentionally diverges from OGP's SysV-plus-systemd-oneshot wrapper.
- `agent_conf.sh` writes GSP update source fields and defaults `agent_auto_update=0`. This diverges from OGP Linux, where restart-time auto-update defaults to yes.
- `gsp_agent_run` is a small guard and crash loop. It refuses root, requires valid config, then runs `gsp_agent.pl`; it does not implement OGP restart-time update.
- `gsp_agent.pl` contains Panel-driven update commands, including `agent_self_update`, `component_update`, and `agent_update_status`. That is GSP-specific and should remain Panel-authoritative.

Broken or incomplete items:

- Linux restart-time auto-update config exists, but the canonical startup wrapper does not use it.
- The wrapper's hard root refusal is safer than OGP's warning behavior, but it is a behavioral difference that installers and docs must consistently expect.
- The GSP Linux path and service model are coherent, but docs must explicitly state that GSP does not follow OGP's automatic update-on-service-start default unless that behavior is deliberately restored.

## Current GSP Windows Findings

Current Windows files inspected:

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
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/AGENT_ARCHITECTURE.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/CYGWIN_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/COMMAND_EXECUTION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PROCESS_MANAGEMENT.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/PANEL_INTEGRATION.md`
- `/home/dev/Projects/GSP/GSP-Agent-Windows/docs/WINDOWS_AGENT_UPDATE_BAT.md`

Divergences:

- `GSP64/agent_start.bat` is the apparent canonical root launcher. It validates bundled Cygwin, creates default configs, requires Windows user `gameserver`, validates Perl, removes stale PID files, and runs `/GSP/gsp_agent.pl` in the same console.
- `GSP64/agent_start.bat` does not call `GSP64/GSP/Install/agent_start_cygwin.sh`, so the only script that implements restart-time update is not on the canonical startup path.
- `GSP64/GSP/Install/agent_start.bat` duplicates launcher behavior and expects `/GSP/Install/agent_start_cygwin.sh`. It is not the root launcher currently documented for users.
- `GSP64/GSP/Install/agent_start_cygwin.sh` is GSP-specific and stale. It defaults to `http://forge.runlevelsystems.com/dev/GSP.git`, branch `Panel-unstable`, and a raw path under `Agent-Windows/GSP64/GSP/gsp_agent.pl`.
- `GSP64/GSP/Cfg/bash_prefs.cfg.default` contains the same obsolete update source defaults.
- `Installer/Install-GSP-WindowsAgent.ps1` defaults to `https://github.com/OpenGamePanel/GSP-Agent-Windows.git` and branch `master`, not the current GSP split repo unstable branch.
- `Installer/Install-GSP-WindowsAgent.ps1` preserves top-level paths under `$AgentDir`, while the real runtime config is under `GSP64\GSP\Cfg`.
- `Installer/Install-GSP-WindowsAgent.ps1` creates a Scheduled Task as `SYSTEM`, while OGP's Windows installer model is based around `cyg_server` and the current root launcher expects a Windows `gameserver` user.
- `Installer/Update-GSP-WindowsAgent.ps1` defaults to branch `master`, broadly kills host `bash` and `perl` processes, preserves the wrong top-level runtime paths, performs a hard reset, validates with `perl.exe` from PATH instead of bundled Cygwin Perl, and can report success even after validation failure.
- `GSP64/agent_update.bat` is a custom manual git-reset helper. It targets branch `unstable`, but it depends on a Git worktree runtime and does not define a safe customer-data boundary.
- `bin/gsp_agent` is an OGP-style wrapper renamed for GSP. It is not used by the root batch startup flow and appears obsolete unless a separate service path still calls it.

Broken or incomplete items:

- Windows has multiple startup/update entry points with conflicting assumptions.
- Restart-time update behavior is configured in defaults and helper scripts but is not active on the canonical root launcher path.
- Update source defaults still point at obsolete forge URLs or OpenGamePanel GitHub paths.
- Installer and updater preservation paths do not match the current `GSP64\GSP` runtime layout.
- The service account model is inconsistent: official OGP uses `cyg_server`, current launcher requires `gameserver`, and the PowerShell installer creates a task as `SYSTEM`.
- Host-wide process killing in the updater is unsafe for shared hosts.

## Downstream Panel Integration Findings

Panel files inspected:

- `/home/dev/Projects/GSP/Panel/includes/lib_remote.php`
- `/home/dev/Projects/GSP/Panel/modules/server/agent_interface.php`
- `/home/dev/Projects/GSP/Panel/modules/server/restart.php`
- `/home/dev/Projects/GSP/Panel/modules/server/agent_helpers.php`
- `/home/dev/Projects/GSP/Panel/docs/architecture/PANEL_AGENT_COMMANDS.md`
- `/home/dev/Projects/GSP/Panel/docs/features/INSTALLERS.md`
- `/home/dev/Projects/GSP/Panel/docs/agents/WINDOWS_AGENT.md`

Findings:

- `modules/server/agent_interface.php` calls `$remote->agent_self_update()` and `$remote->agent_update_status()`.
- `modules/server/agent_helpers.php` calls `$remote->agent_resource_snapshot()`.
- `docs/architecture/PANEL_AGENT_COMMANDS.md` documents `agent_self_update`, `agent_update_status`, `agent_resource_snapshot`, and `agent_version` wrapper methods.
- `includes/lib_remote.php` currently implements `agent_restart()` and `component_update()` in the inspected section, but no concrete wrapper methods for `agent_self_update()`, `agent_update_status()`, `agent_resource_snapshot()`, or `agent_version()` were found.

This is a downstream integration risk for later workflow steps. It was not changed in this report-only step.

## Bidirectional Execution Flow Validation

### Original OGP Linux

Startup direction:

1. Admin runs installer from `OGP-Agent-Linux/install.sh`.
2. Installer runs `agent_conf.sh`.
3. Installer installs SysV init plus systemd oneshot service.
4. Service starts `ogp_agent_init start`.
5. Init path starts `ogp_agent_run`.
6. `ogp_agent_run` optionally updates source on restart.
7. `ogp_agent_run` starts `ogp_agent.pl` and crash-restarts it.
8. `ogp_agent.pl` registers XML-RPC methods and processes startup marker files.

Panel direction:

1. Panel calls XML-RPC command.
2. `ogp_agent.pl` executes lifecycle, file, status, and query actions.
3. Agent returns structured or scalar XML-RPC response.
4. Panel updates UI and database state.

### Current GSP Linux

Startup direction:

1. Admin runs `install.sh` or starts systemd service.
2. `systemd/gsp_agent.service` runs `gsp_agent_run` directly as `{GSP_AGENT_USER}`.
3. `gsp_agent_run` refuses root, validates config, and starts `gsp_agent.pl`.
4. `gsp_agent.pl` registers XML-RPC methods and processes runtime commands.

Panel direction:

1. Panel calls XML-RPC through `includes/lib_remote.php`.
2. `gsp_agent.pl` executes server lifecycle, status, update, and resource commands.
3. Agent returns XML-RPC response.
4. Panel consumes the response through module code.

Gap:

- Restart-time update is absent from the current Linux startup direction, while Panel-driven update exists in the XML-RPC direction.

### Original OGP Windows

Startup direction:

1. Admin installs the Easy Installer Cygwin package.
2. Installer prepares Cygwin, dependencies, and `cyg_server`.
3. Admin or service starts the packaged batch launcher.
4. Batch/Cygwin path starts `OGP/ogp_agent.pl`.
5. `ogp_agent.pl` validates non-root execution, creates runtime directories, processes startup markers, and registers XML-RPC methods.

Panel direction:

1. Panel calls XML-RPC command.
2. `ogp_agent.pl` executes the request.
3. Agent returns XML-RPC response.

### Current GSP Windows

Startup direction:

1. Admin runs `GSP64/agent_start.bat`.
2. Batch validates bundled Cygwin and root paths.
3. Batch requires Windows user `gameserver`.
4. Batch validates bundled Perl and clears stale PID files.
5. Batch runs `bash -lc "cd /GSP && ./gsp_agent.pl -pidfile /GSP/gsp_agent_run.pid"`.
6. `gsp_agent.pl` registers XML-RPC methods and processes runtime commands.

Panel direction:

1. Panel calls XML-RPC through `includes/lib_remote.php`.
2. `GSP64/GSP/gsp_agent.pl` executes server lifecycle, status, update, and resource commands.
3. Agent returns XML-RPC response.

Gap:

- `GSP64/GSP/Install/agent_start_cygwin.sh` contains a restart-time update path, but `GSP64/agent_start.bat` does not call it.
- PowerShell installer and updater flows do not match the root batch startup flow or the real runtime directory layout.

## Recommended Target Architecture

### Common Rules

- Keep Panel authoritative for business decisions and user-triggered update orchestration.
- Keep agents focused on execution, local validation, safe preservation, status reporting, and rollback.
- Define one canonical startup path per platform.
- Define one canonical update path per platform for service restart and one Panel-driven update path for admin actions.
- Do not delete, reset, or overwrite customer data, game server files, saves, Workshop content, logs, custom scripts, or generated runtime config.
- Move or ignore mutable runtime data so Git operations cannot treat customer data as source code.

### Linux Target

- Keep the split `GSP-Agent-Linux` repository and direct systemd service model if this remains the intended GSP architecture.
- Make `gsp_agent_run` the single canonical service/manual foreground wrapper.
- Explicitly implement or explicitly remove restart-time auto-update support. If implemented, it should be GSP-specific, default off unless product policy changes, and preserve only source-managed files while excluding runtime/customer paths.
- Keep Panel-driven `agent_self_update` as the primary admin update mechanism because it stages, backs up, restarts, health-checks, and rolls back.
- Document the root guard as a deliberate GSP safety behavior.
- Keep config generation in `agent_conf.sh`, but align defaults and docs with the actual wrapper behavior.

### Windows Target

- Make `GSP64/agent_start.bat` the single canonical user-facing launcher.
- Either inline the validated Cygwin helper behavior into the root launcher path or make the root launcher call exactly one maintained Cygwin startup helper.
- Retire or quarantine duplicate launchers and obsolete wrappers after the canonical path is implemented.
- Replace obsolete update defaults with the current `GSP-Agent-Windows` repo, branch `unstable`, and a valid path to `GSP64/GSP/gsp_agent.pl`.
- Decide one service account model. The current candidates are OGP-style `cyg_server`, GSP-style `gameserver`, or Windows Scheduled Task `SYSTEM`; they must not coexist silently.
- Rework PowerShell install/update scripts to preserve real runtime paths under `GSP64\GSP`, validate with bundled Cygwin Perl, avoid host-wide process kills, and health-check the XML-RPC endpoint after restart.
- Treat any restart-time Windows update helper as GSP packaging, not verified OGP upstream behavior, unless the matching Easy Installer source is later verified.

### Panel Target

- Add or restore missing `includes/lib_remote.php` wrapper methods before relying on `agent_self_update`, `agent_update_status`, `agent_resource_snapshot`, or `agent_version` from Panel UI code.
- Keep command names and payload shapes aligned with both Linux and Windows agents before changing runtime code.

## Step 1 Decision

Step 1 is complete and verified.

No runtime or installer implementation changes were made.

The highest-risk divergences for later steps are:

1. Linux OGP restart-time update defaulted on, while current GSP Linux has disabled config and no wrapper implementation.
2. Windows OGP source does not verify a restart-time update wrapper, while current GSP Windows has a stale helper that is not on the canonical startup path.
3. Current GSP Windows has duplicated startup/update flows with conflicting repository, branch, path, preservation, and service-account assumptions.
4. Panel docs and modules expect several newer remote wrapper methods that were not found in `includes/lib_remote.php`.
