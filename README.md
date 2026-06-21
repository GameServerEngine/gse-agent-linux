# GSP Linux Agent

Perl-based Linux execution agent for GameServer Panel. The agent receives signed RPC calls from the GSP Panel and launches customer game servers on Linux hosts.

## Default Layout

- install directory: `/home/gameserver/GSP`
- run script: `gsp_agent_run`
- legacy run wrapper: `ogp_agent_run`
- systemd service: `gsp_agent.service`
- config directory: `/home/gameserver/GSP/Cfg/`
- main log: `/home/gameserver/GSP/gsp_agent.log`
- screen logs: `/home/gameserver/GSP/screenlogs/`
- server-content runtime: `/home/gameserver/GSP/_gsp_content/`

Legacy OGP script names are retained only where the Panel or older installs may still expect them.

## Guided Install

```bash
chmod +x install_agent_prereqs.sh install.sh agent_conf.sh gsp_agent_run ogp_agent_run
sudo ./install_agent_prereqs.sh
sudo ./install.sh
```

The installer prompts for the install directory, Linux agent user, service name, agent key/shared secret, listen address, Panel URLs, remote server ID, FTP mode, and whether to install/start the systemd service.

Use the same agent key/shared secret configured in the GSP Panel remote-server record.

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

## Documentation

- [Linux Agent Operations Guide](documentation/agent-guide.md)
- [Panel Integration](docs/PANEL_INTEGRATION.md)
- [Agent Activity Events](docs/AGENT_ACTIVITY_EVENTS.md)

## Related Projects

- GSP Panel: control plane that sends agent commands
- GSP-Agent-Windows: Windows/Cygwin execution engine
