# Linux Agent Operations Guide

This guide covers installation, configuration, service management, and troubleshooting for the GSE Linux Agent.

## Purpose

The Linux agent exposes the RPC endpoint that allows Gameserver Engine to install, start, stop, update, and monitor game servers on Linux hosts.

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
chmod +x install.sh agent_conf.sh gsp_agent_run
sudo ./install.sh
```

Default choices:

- install directory: `/home/gameserver/GSP`
- Linux user: `gameserver`
- service name: `gsp_agent`
- log file: `/home/gameserver/GSP/gsp_agent.log`
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

`--repair` refreshes agent code from the configured repo and preserves existing config unless reconfiguration is requested. `--reconfigure` regenerates only `Cfg/Config.pm`, `Cfg/Preferences.pm`, and `Cfg/bash_prefs.cfg`.

`--uninstall` removes the managed systemd service and known source-owned agent files. It preserves `Cfg/`, `ServerFiles/`, `Schedule/`, `logs/`, `screenlogs/`, `steamcmd/`, `startups/`, `runtime_status/`, `events/`, `tmp/`, `shared/`, Workshop/content runtime folders, backups, credentials, PID/update state, and customer-created files by default. `--purge-data` removes the entire install directory and should only be used after an operator has confirmed the host contains no customer data that must be retained.

## Configuration Prompts

The installer calls `agent_conf.sh --guided`. The guided configuration asks for the agent key/shared secret, listen IP, listen port, Panel API URL, Panel event receiver URL, remote server ID, FTP management setting, FTP method, game-server autorestart setting, restart-time agent auto-update setting, update repository URL, update branch, and update source path.

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

- `gsp_manages_ftp`
- `gsp_autorestart_server`
- `ftp_method`
- `PortValidationEnabled`
- `StartupValidationTimeoutSeconds`
- `PortCheckIntervalSeconds`

Compatibility aliases are still written for older panel/agent paths:

- `gsp_manages_ftp`
- `gsp_autorestart_server`

The `gsp_` config keys, `X-GSP-*` event headers, `GSP_*` screen-session prefixes, `GSP_WORKSHOP_*` completion markers, `gsp_agent` service/script names, and default `/home/gameserver/GSP` runtime path remain compatibility identifiers. Do not rename them without a coordinated Panel and installed-agent migration.

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
- `_gsp_content/hooks/`
- `_gsp_content/generated/`
- `_gsp_content/runtime/`

The `_gsp_content/runtime/server_content.pids` file is reserved for generated server-content hook processes. During stop/restart cleanup, hook watchdog PIDs are stopped before hook application PIDs. The main game server watchdog PID should not be stored in this file.

Legacy `_alsoRun.pid` files are treated as compatibility input. Stop, restart, and force-stop import matching helper PIDs into the server-content cleanup path before escalating to main server PID and port cleanup.

## systemd Service

New installs use:

- `gsp_agent.service`

Useful commands:

```bash
sudo systemctl status gsp_agent
sudo systemctl restart gsp_agent
sudo systemctl stop gsp_agent
sudo journalctl -u gsp_agent -f
```

The generated unit runs as the selected agent user, sets `WorkingDirectory` to the selected install directory, and starts `gsp_agent_run`.

## Production And Debug Workflows

Production hosts should run the agent through systemd:

```bash
sudo systemctl enable gsp_agent
sudo systemctl restart gsp_agent
sudo systemctl status gsp_agent
```

Use foreground mode only while debugging from an interactive shell:

```bash
cd /home/gameserver/GSP
./gsp_agent_run --log-stdout
```

The same `gsp_agent_run` wrapper is used by systemd and by foreground debugging. At startup it validates configuration, refuses root execution, takes an agent-local lock, checks that the configured agent port is available, applies a queued restart-time update when `agent_auto_update=1`, and then starts `gsp_agent.pl`. If another valid wrapper instance or listener already owns the configured port, startup fails without killing unrelated processes.

## Server Status Contract

`server_status` reports the same shared readiness fields expected by the Panel on both Linux and Windows. Linux keeps Linux-native process and port detection, but returns `PortValidationEnabled`, `StartupValidationTimeoutSeconds`, `PortCheckIntervalSeconds`, `ExpectedPorts`, `ListeningPorts`, `MissingPorts`, `CPUUsage`, `MemoryUsage`, `linux_pid`, and compatibility aliases such as `ProcessRunning` and `StatusState`.

## Restart-Time Updates

If `agent_auto_update=1`, `gsp_agent_run` checks for a pending `gsp_agent_update_request.json` on service or foreground restart. The request is created by the `agent_self_update` RPC and contains the Git repo, branch, and source path selected by the Panel. The wrapper resolves the remote branch head, clones to a temporary staging directory, validates `gsp_agent.pl` with `perl -c`, validates the wrapper with `bash -n`, creates one local backup archive, and copies source-owned files into the install directory while preserving config and runtime/customer data.

The wrapper records update status in:

- `/home/gameserver/GSP/gsp_agent_update_state.json`
- `/home/gameserver/GSP/gsp_agent_update.log`

If the copied agent fails post-copy validation, the wrapper restores the backup immediately. If the updated agent exits during first startup, the wrapper attempts one rollback and relaunches with auto-update suppressed to avoid a failure loop.

Terminal states are recorded as `completed`, `failed`, or `rolled_back`, and the pending request is removed so the same failed request is not retried on every restart. If `agent_auto_update=0`, the request remains `pending` until an admin enables restart-time updates or replaces the request.

## Logs

- main agent log: `/home/gameserver/GSP/gsp_agent.log`
- systemd journal: `sudo journalctl -u gsp_agent -f`
- screen logs: `/home/gameserver/GSP/screenlogs/`
- activity event offline queue: `/home/gameserver/GSP/events/pending-events.jsonl`

## Manual Reconfiguration

```bash
cd /home/gameserver/GSP
./agent_conf.sh --guided --install-dir /home/gameserver/GSP --agent-user gameserver
sudo systemctl restart gsp_agent
```

Use noninteractive flags when automating:

```bash
./agent_conf.sh \
  --install-dir /home/gameserver/GSP \
  --agent-user gameserver \
  --key CHANGE_ME \
  --listen-ip 0.0.0.0 \
  --listen-port 12679 \
  --web-api-url https://panel.example.com/gsp_api.php \
  --agent-event-url https://panel.example.com/agent_event_receiver.php \
  --remote-server-id 1 \
  --repo-url https://git.runlevelsystems.com/GSE/Agent-Linux \
  --repo-branch unstable \
  --source-path .
```

## FTP Configuration

Default FTP mode is PureFTPd-compatible account management:

- `gsp_manages_ftp => '1'`
- `ftp_method => 'PureFTPd'`

The Windows agent uses the same Pure-FTPd virtual-user command model through Cygwin, so Panel `ftp_mgr` calls should behave consistently across Linux and Windows agents.

Set `gsp_manages_ftp` to `0` if FTP accounts are managed outside the agent.

## Troubleshooting

Authentication failed or Panel shows agent offline:

- confirm `key` in `Cfg/Config.pm` matches the Panel remote-server key
- confirm `listen_port` is reachable from the Panel host
- check firewall rules

Polkit or systemctl authentication failure:

- run `sudo ./install.sh`
- do not start with a non-root partial install
- inspect `sudo journalctl -u gsp_agent -f`

Wrong install path or old `/home/gameserver/GSP` log path:

- rerun `./agent_conf.sh --guided --install-dir /home/gameserver/GSP`
- confirm `Cfg/Config.pm` has `logfile => '/home/gameserver/GSP/gsp_agent.log'`
- confirm the systemd unit `WorkingDirectory` points to `/home/gameserver/GSP`

Missing packages:

- rerun `sudo ./install_agent_prereqs.sh`
- confirm `screen`, `rsync`, `perl`, `git`, `curl`, and required Perl modules are installed

Service failed:

- run `sudo systemctl status gsp_agent`
- run `sudo journalctl -u gsp_agent -f`
- run `perl -c /home/gameserver/GSP/gsp_agent.pl`
- check `/home/gameserver/GSP/gsp_agent_update_state.json` if restart-time update is enabled

Duplicate agent startup refused:

- confirm no other agent instance is already using the configured `listen_port`
- remove `gsp_agent_run.pid` only if the PID inside it no longer exists
- do not kill unrelated processes that happen to contain `gsp_agent` in their command line

Config missing or invalid:

- run `./agent_conf.sh --guided`
- replace placeholder `CHANGE_ME_PANEL_AGENT_KEY`
- verify `Cfg/Config.pm` is readable by the agent user

## Clean Reinstall

```bash
sudo systemctl stop gsp_agent || true
sudo systemctl disable gsp_agent || true
sudo rm -f /etc/systemd/system/gsp_agent.service
sudo systemctl daemon-reload
```

Only remove `/home/gameserver/GSP` after confirming it does not contain customer server data, logs, SteamCMD data, or local configuration that must be preserved.
