# Linux Agent Operations Guide

This guide covers installation, configuration, service management, and troubleshooting for the GSP Linux Agent.

## Purpose

The Linux agent exposes the RPC endpoint that allows GameServer Panel to install, start, stop, update, and monitor game servers on Linux hosts.

## Supported Platforms

- Ubuntu 20.04, 22.04, and 24.04 LTS
- Debian 11 and 12
- other modern Linux distributions with Perl, GNU Screen, rsync, sudo, and systemd or compatible service management

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
chmod +x install.sh agent_conf.sh gsp_agent_run ogp_agent_run
sudo ./install.sh
```

Default choices:

- install directory: `/home/gameserver/GSP`
- Linux user: `gameserver`
- service name: `gsp_agent`
- log file: `/home/gameserver/GSP/gsp_agent.log`

The installer runs as root from the start. If launched without root and `sudo` is available, it re-executes itself through `sudo` before creating users, copying files, or installing systemd units.

## Configuration Prompts

The installer calls `agent_conf.sh --guided`. The guided configuration asks for the agent key/shared secret, listen IP, listen port, Panel API URL, Panel event receiver URL, remote server ID, FTP management setting, FTP method, game-server autorestart setting, and restart-time agent auto-update setting.

The agent key/shared secret must match the remote-server record in the GSP Panel.

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

- `ogp_manages_ftp`
- `ogp_autorestart_server`

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
  --web-api-url https://panel.example.com/ogp_api.php \
  --agent-event-url https://panel.example.com/agent_event_receiver.php \
  --remote-server-id 1
```

## FTP Configuration

Default FTP mode is PureFTPd-compatible account management:

- `gsp_manages_ftp => '1'`
- `ftp_method => 'PureFTPd'`

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

Wrong install path or old `/home/gameserver/OGP` log path:

- rerun `./agent_conf.sh --guided --install-dir /home/gameserver/GSP`
- confirm `Cfg/Config.pm` has `logfile => '/home/gameserver/GSP/gsp_agent.log'`
- confirm the systemd unit `WorkingDirectory` points to `/home/gameserver/GSP`

Missing packages:

- rerun `sudo ./install_agent_prereqs.sh`
- confirm `screen`, `rsync`, `perl`, `git`, `curl`, and required Perl modules are installed

Service failed:

- run `sudo systemctl status gsp_agent`
- run `sudo journalctl -u gsp_agent -f`
- run `perl -c /home/gameserver/GSP/ogp_agent.pl`

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
