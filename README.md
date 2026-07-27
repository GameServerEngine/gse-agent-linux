# GSE Linux Agent

Perl-based Linux execution agent for GameServer Engine (GSE). The agent receives signed RPC calls from the GSE Panel and launches customer game servers on Linux hosts.

## Default Layout

- install directory: `/home/gameserver/GSP`
- run script: `gsp_agent_run`
- systemd service: `gsp_agent.service`
- config directory: `/home/gameserver/GSP/Cfg/`
- main log: `/home/gameserver/GSP/gsp_agent.log`
- screen logs: `/home/gameserver/GSP/screenlogs/`
- server-content runtime: `/home/gameserver/GSP/_gsp_content/`
- SteamCMD bootstrap: `/home/gameserver/GSP/steamcmd/steamcmd.sh`

Legacy `GSP` script names, default paths, config keys, RPC headers, screen-session prefixes, and Workshop markers are retained only where the Panel or older installs may still expect them.

## Guided Install

```bash
chmod +x install_agent_prereqs.sh install.sh agent_conf.sh gsp_agent_run
sudo ./install_agent_prereqs.sh
sudo ./install.sh
```

The installer currently targets Debian/Ubuntu package families. It prompts for install directory, Linux agent user, service name, Git repo URL/branch/source path, agent key/shared secret, listen address, Panel URLs, remote server ID, FTP mode, restart-time update behavior, and whether to install/start the systemd service.

Use the same agent key/shared secret configured in the GSE Panel remote-server record.

Repair or reconfigure an existing install with:

```bash
sudo ./install.sh --repair
sudo ./install.sh --reconfigure
```

Uninstall the managed service and source-owned agent files while preserving configuration, game-server homes, logs, SteamCMD data, Workshop content, runtime state, and customer files:

```bash
sudo ./install.sh --uninstall
```

`--purge-data` removes the full install directory and should only be used after separately backing up customer data.

## SteamCMD Bootstrap

The Linux agent source includes the normal Linux SteamCMD bootstrap under `steamcmd/` so offline installs and repairs can restore `steamcmd/steamcmd.sh` without downloading SteamCMD during install or agent startup.

Agent startup does not run SteamCMD and does not require internet access. Non-Steam servers work without SteamCMD. Steam installs, Steam updates, and Steam Workshop operations still require a usable `steamcmd/steamcmd.sh`; SteamCMD may self-update and download content when those Steam-specific operations run and internet access is available.

Install, repair, and restart-time update preserve an existing installed `steamcmd/` directory. They restore missing bundled bootstrap files only and do not overwrite SteamCMD runtime state, `steamapps/`, logs, credentials, or self-updated files that already exist.

## Service Commands

```bash
sudo systemctl status gsp_agent
sudo journalctl -u gsp_agent -f
sudo systemctl restart gsp_agent
tail -f /home/gameserver/GSP/gsp_agent.log
```

## Manual Configuration

```bash
./agent_conf.sh --guided --install-dir /home/gameserver/GSP --agent-user gameserver
```

Generated files:

- `Cfg/Config.pm`
- `Cfg/Preferences.pm`
- `Cfg/bash_prefs.cfg`

`Cfg/bash_prefs.cfg` controls whether queued restart-time updates may run. The running agent records `agent_self_update` requests as pending state, and `gsp_agent_run` applies them from the requested Git repo, branch, and source path before the agent starts. The service and foreground wrapper both use `gsp_agent_run`; the wrapper refuses duplicate startup when the configured agent port or a valid wrapper lock is already active.

## Documentation

- [Linux Agent Operations Guide](documentation/agent-guide.md)
- [Panel Integration](docs/PANEL_INTEGRATION.md)
- [Game Server Lifecycle Contract](docs/GAME_SERVER_LIFECYCLE_CONTRACT.md)
- [Agent Activity Events](docs/AGENT_ACTIVITY_EVENTS.md)

## Related Projects

- GSE Panel: control plane that sends agent commands
- GSE Agent-Windows: Windows/Cygwin execution engine
