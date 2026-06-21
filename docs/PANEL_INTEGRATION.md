# GSP Linux Agent Panel Integration

Workspace reference: [`GSP-WORKSPACE.md`](../../GSP-WORKSPACE.md)

The Panel is authoritative. The Linux agent executes the work the Panel requests.

## Current Install And Config Defaults

New Linux installs default to:

- agent root: `/home/gameserver/GSP`
- run script: `gsp_agent_run`
- service: `gsp_agent.service`
- log file: `/home/gameserver/GSP/gsp_agent.log`

Legacy names such as `ogp_agent_run` remain wrappers or protocol compatibility details only.

## Legacy Workshop RPC

The dedicated Panel `steam_workshop` module still uses the legacy `steam_workshop` XML-RPC call.

Current compatibility rule:

- if the Panel sends a blank `config_file_path`, the Linux agent runs post-install logic only
- the generated script must skip all `cat` / regex / config-write logic in that case
- `WorkshopModsInfo` is still written so the Panel can list/uninstall installed items even when no game config file is edited
- new installs write per-home records under `WorkshopModsInfo/home_<home_id>/`
- each record stores mod string, Workshop item ID, title, installed folder/path, Workshop App ID, install status, and timestamps
- the generated job writes `<game_home>/WorkshopInstallStatus.json` as `running`, `completed`, or `failed`
- the generated job prints `GSP_WORKSHOP_INSTALL_COMPLETE` or `GSP_WORKSHOP_INSTALL_FAILED` so the Panel can avoid stale `Update in progress` displays if the generic update screen lingers

## Server Content Hook Runtime

The Linux agent prepares this runtime layout for generated content hooks:

- `_gsp_content/hooks/`
- `_gsp_content/generated/`
- `_gsp_content/runtime/`
- `_gsp_content/runtime/server_content.pids`

During stop/restart, hook watchdog PIDs are cleaned up before hook application PIDs. Main game server watchdog PIDs should not be written to `server_content.pids`.
