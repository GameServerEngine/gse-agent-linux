# Linux Agent Operations Guide

This guide covers installation, configuration, service management, and troubleshooting for the GSE Linux Agent.

## Purpose

The Linux agent exposes the RPC endpoint that allows GameServer Engine (GSE) to install, start, stop, update, and monitor game servers on Linux hosts.

## Supported Platforms

- Ubuntu 20.04, 22.04, and 24.04 LTS
- Debian 11 and 12

The packaged prerequisite installer is intentionally Debian/Ubuntu first. Other distributions are not rejected by the agent runtime, but package installation must be handled manually until a verified installer path exists.

## Prerequisites

For Debian and Ubuntu hosts:

```bash
chmod +x install_agent_prereqs.sh
sudo ./install_agent_prereqs.sh
```

The prerequisite script installs required Perl modules, `screen`, `rsync`, `sudo`, `unzip`, `git`, `curl`, PureFTPd, and related utilities. It no longer attempts obsolete Ubuntu packages such as `libgcc1:i386`, `lib32gcc1`, `libcrypt-xxtea-perl`, or `libfile-basename-perl`.

The script may show normal `needrestart` output about services, kernels, or VM guests. That output comes from the OS package manager and does not mean the GSP agent installer failed.

## Guided Installation

```bash
chmod +x install.sh agent_conf.sh agent_core_run
sudo ./install.sh
```

Default choices:

- install directory: `/home/gameserver/GSP`
- Linux user: `gameserver`
- service name: `agent_core`
- log file: `/home/gameserver/GSP/agent_core.log`
- Git repository: `https://git.runlevelsystems.com/GSE/Agent-Linux`
- Git branch: `unstable`
- repository source path: `.`

The installer runs as root from the start. If launched without root and `sudo` is available, it re-executes itself through `sudo` before creating users, copying files, or installing systemd units.

The install and repair modes clone the configured repository and branch into a temporary directory, copy source-owned files into the install directory, and preserve runtime config and customer data. Clone failures prompt for retry instead of silently falling back to local files.

Repair and reconfiguration modes:

```bash
sudo ./install.sh --repair
sudo ./install.sh --reconfigure
sudo ./install.sh --uninstall
```

`--repair` refreshes agent code from the configured repo and preserves existing config unless reconfiguration is requested. It also restores missing bundled SteamCMD bootstrap files under `steamcmd/` without overwriting an existing SteamCMD runtime. `--reconfigure` regenerates only `Cfg/Config.pm`, `Cfg/Preferences.pm`, and `Cfg/bash_prefs.cfg`.

`--uninstall` removes the managed systemd service and known source-owned agent files. It preserves `Cfg/`, `ServerFiles/`, `Schedule/`, `logs/`, `screenlogs/`, `steamcmd/`, `startups/`, `runtime_status/`, `events/`, `tmp/`, `shared/`, Workshop/content runtime folders, backups, credentials, PID/update state, and customer-created files by default. `--purge-data` removes the entire install directory and should only be used after an operator has confirmed the host contains no customer data that must be retained.

## Configuration Prompts

The installer calls `agent_conf.sh --guided`. The guided configuration asks for the agent key/shared secret, listen IP, listen port, Panel API URL, Panel event receiver URL, remote game server ID, FTP management setting, FTP method, game-server autorestart setting, restart-time agent auto-update setting, update repository URL, update branch, and update source path.

The agent key/shared secret must match the remote-server record in the GSE Panel.

## Configuration Files

Runtime config lives in:

- `/home/gameserver/GSP/Cfg/Config.pm`
- `/home/gameserver/GSP/Cfg/Preferences.pm`
- `/home/gameserver/GSP/Cfg/bash_prefs.cfg`

Important `Config.pm` keys:

- `logfile`
- `listen_ip`
- `listen_port`
- `key`
- `web_api_url`
- `agent_event_url`
- `remote_server_id`

Important `Preferences.pm` keys:

- `manages_ftp`
- `autorestart_server`
- `ftp_method`
- `PortValidationEnabled`
- `StartupValidationTimeoutSeconds`
- `PortCheckIntervalSeconds`

Compatibility aliases are still written for older panel/agent paths:

- `manages_ftp`
- `autorestart_server`

The `gsp_` config keys, `X-GSP-*` event headers, `GSP_*` screen-session prefixes, `WORKSHOP_*` completion markers, `agent_core` service/script names, and default `/home/gameserver/GSP` runtime path remain compatibility identifiers. Do not rename them without a coordinated Panel and installed-agent migration.

Important `bash_prefs.cfg` keys:

- `agent_auto_update`
- `agent_update_repo_url`
- `agent_update_branch`
- `agent_update_source_path`

## Folder Layout

Default runtime folders:

- `Cfg/`
- `logs/`
- `tmp/`
- `screenlogs/`
- `runtime_status/`
- `events/`
- `steamcmd/`
- `_game_content/hooks/`
- `_game_content/generated/`
- `_game_content/runtime/`

The repository ships the Linux SteamCMD bootstrap in `steamcmd/`, with the runtime executable at `steamcmd/steamcmd.sh`. The installer and restart-time updater validate this bootstrap and restore missing bootstrap files during install or repair. They preserve existing installed SteamCMD state, including self-updated files, `steamapps/`, logs, credentials, cache, and downloaded content.

Agent startup does not run SteamCMD and does not require internet access. Non-Steam game servers can start and operate without SteamCMD. Steam-specific installs, updates, version checks, and Workshop operations call the SteamCMD helper at operation time; those operations fail with a Steam-specific error if `steamcmd/steamcmd.sh` is missing or unusable, and may require internet access for SteamCMD self-update and content downloads.

The `_game_content/runtime/server_content.pids` file is reserved for generated server-content hook processes. During stop/restart cleanup, hook watchdog PIDs are stopped before hook application PIDs. The main game server watchdog PID should not be stored in this file.

Legacy `_alsoRun.pid` files are treated as compatibility input. Stop, restart, force-stop, and start preflight import matching helper PIDs into the server-content cleanup path before escalating to main game server PID and port cleanup.

Every Start regenerates `<game_home>/serverStart.sh` and launches it directly in the named screen session. The watchdog writes `<game_home>/watchdog.pid`, keeps `game.pid`, `game.launch_ts`, and optional `bot.pid` in the game home, checks every 30 seconds, and exits without starting game or sidecar processes unless `status.running` is the only readable desired-state marker. A game exit within 120 seconds of launch is treated as a crash loop: the watchdog writes `status.stopped`, terminates managed game/bot process groups, records a concise screen-log event, and exits. Optional bot settings are read only from `<game_home>/bot.def`. Home PID cleanup processes `watchdog.pid` before `bot.pid` and `game.pid`, using the shared Linux hard-stop helper.

In lifecycle management, `game_home` is the server-ID management directory. The game payload root is `game_home/<validated XML game_key>`. The Linux agent validates `game_key` as a single safe directory name and rejects empty keys, traversal, slashes, backslashes, drive prefixes, colons, control characters, reserved device names, trailing dots, and any resolved path that would escape the management directory. Game executables, game logs, configs, mods, missions, saves, Workshop payloads, and user content resolve beneath that payload root. Watchdogs, desired-state markers, PID files, bot definitions, Server Content management runtime, and install control scripts stay in the management directory or agent temp/runtime directories.

## systemd Service

New installs use:

- `agent_core.service`

Useful commands:

```bash
sudo systemctl status agent_core
sudo systemctl restart agent_core
sudo systemctl stop agent_core
sudo journalctl -u agent_core -f
```

The generated unit runs as the selected agent user, sets `WorkingDirectory` to the selected install directory, and starts `agent_core_run`.

## Production And Debug Workflows

Production hosts should run the agent through systemd:

```bash
sudo systemctl enable agent_core
sudo systemctl restart agent_core
sudo systemctl status agent_core
```

Use foreground mode only while debugging from an interactive shell:

```bash
cd /home/gameserver/GSP
./agent_core_run --log-stdout
```

The same `agent_core_run` wrapper is used by systemd and by foreground debugging. At startup it validates configuration, refuses root execution, takes an agent-local lock, checks that the configured agent port is available, applies a queued restart-time update when `agent_auto_update=1`, and then starts `agent_core.pl`. If another valid wrapper instance or listener already owns the configured port, startup fails without killing unrelated processes.

## Server Status Contract

`server_status` reports the same shared readiness fields expected by the Panel on both Linux and Windows. Linux keeps Linux-native process and port detection, but returns `PortValidationEnabled`, `StartupValidationTimeoutSeconds`, `PortCheckIntervalSeconds`, `ExpectedPorts`, `ListeningPorts`, `MissingPorts`, `CPUUsage`, `MemoryUsage`, `linux_pid`, and compatibility aliases such as `ProcessRunning` and `StatusState`.

Normal stop and force-stop write `<game_home>/status.stopped` before cleanup. A new start first performs the same cleanup while stopped, verifies the named screen, tracked PIDs, and TCP/UDP game-port owners are absent, then writes `<game_home>/status.running` immediately before launching the guarded watchdog.

On agent restart, automatic startup registration is honored only when the management directory still contains a valid `status.running` marker. Missing, stopped, unreadable, or conflicting desired-state markers are treated as stopped and skipped.

## Restart-Time Updates

If `agent_auto_update=1`, `agent_core_run` checks for a pending `agent_core_update_request.json` on service or foreground restart. The request is created by the `agent_self_update` RPC and contains the Git repo, branch, and source path selected by the Panel. The wrapper resolves the remote branch head, clones to a temporary staging directory, validates `agent_core.pl` with `perl -c`, validates the wrapper with `bash -n`, creates one local backup archive, and copies source-owned files into the install directory while preserving config and runtime/customer data.

The wrapper records update status in:

- `/home/gameserver/GSP/agent_core_update_state.json`
- `/home/gameserver/GSP/agent_core_update.log`

If the copied agent fails post-copy validation, the wrapper restores the backup immediately. If the updated agent exits during first startup, the wrapper attempts one rollback and relaunches with auto-update suppressed to avoid a failure loop.

Terminal states are recorded as `completed`, `failed`, or `rolled_back`, and the pending request is removed so the same failed request is not retried on every restart. If `agent_auto_update=0`, the request remains `pending` until an admin enables restart-time updates or replaces the request.

## Logs

- main agent log: `/home/gameserver/GSP/agent_core.log`
- systemd journal: `sudo journalctl -u agent_core -f`
- screen logs: `/home/gameserver/GSP/screenlogs/`
- activity event offline queue: `/home/gameserver/GSP/events/pending-events.jsonl`

## Manual Reconfiguration

```bash
cd /home/gameserver/GSP
./agent_conf.sh --guided --install-dir /home/gameserver/GSP --agent-user gameserver
sudo systemctl restart agent_core
```

Use noninteractive flags when automating:

```bash
./agent_conf.sh \
  --install-dir /home/gameserver/GSP \
  --agent-user gameserver \
  --key CHANGE_ME \
  --listen-ip 0.0.0.0 \
  --listen-port 12679 \
  --web-api-url https://panel.example.com/api.php \
  --agent-event-url https://panel.example.com/agent_event_receiver.php \
  --remote-server-id 1 \
  --repo-url https://git.runlevelsystems.com/GSE/Agent-Linux \
  --repo-branch unstable \
  --source-path .
```

## FTP Configuration

Default FTP mode is PureFTPd-compatible account management:

- `manages_ftp => '1'`
- `ftp_method => 'PureFTPd'`

The Windows agent uses the same Pure-FTPd virtual-user command model through Cygwin, so Panel `ftp_mgr` calls should behave consistently across Linux and Windows agents.

Set `manages_ftp` to `0` if FTP accounts are managed outside the agent.

## Troubleshooting

Authentication failed or Panel shows agent offline:

- confirm `key` in `Cfg/Config.pm` matches the Panel remote-server key
- confirm `listen_port` is reachable from the Panel host
- check firewall rules

Polkit or systemctl authentication failure:

- run `sudo ./install.sh`
- do not start with a non-root partial install
- inspect `sudo journalctl -u agent_core -f`

Wrong install path or old `/home/gameserver/GSP` log path:

- rerun `./agent_conf.sh --guided --install-dir /home/gameserver/GSP`
- confirm `Cfg/Config.pm` has `logfile => '/home/gameserver/GSP/agent_core.log'`
- confirm the systemd unit `WorkingDirectory` points to `/home/gameserver/GSP`

Missing packages:

- rerun `sudo ./install_agent_prereqs.sh`
- confirm `screen`, `rsync`, `perl`, `git`, `curl`, and required Perl modules are installed

Service failed:

- run `sudo systemctl status agent_core`
- run `sudo journalctl -u agent_core -f`
- run `perl -c /home/gameserver/GSP/agent_core.pl`
- check `/home/gameserver/GSP/agent_core_update_state.json` if restart-time update is enabled

Duplicate agent startup refused:

- confirm no other agent instance is already using the configured `listen_port`
- remove `agent_core_run.pid` only if the PID inside it no longer exists
- do not kill unrelated processes that happen to contain `agent_core` in their command line

Config missing or invalid:

- run `./agent_conf.sh --guided`
- replace placeholder `CHANGE_ME_PANEL_AGENT_KEY`
- verify `Cfg/Config.pm` is readable by the agent user

## Clean Reinstall

```bash
sudo systemctl stop agent_core || true
sudo systemctl disable agent_core || true
sudo rm -f /etc/systemd/system/agent_core.service
sudo systemctl daemon-reload
```

Only remove `/home/gameserver/GSP` after confirming it does not contain customer game server data, logs, SteamCMD data, or local configuration that must be preserved.
