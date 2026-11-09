# GSE Linux Agent Panel Integration

Workspace reference: [`GSP-WORKSPACE.md`](../../GSP-WORKSPACE.md)

The Panel is authoritative. The Linux agent executes the work the Panel requests.

## Current Install And Config Defaults

New Linux installs default to:

- agent root: `/home/gameserver/GSP`
- run script: `agent_core_run`
- service: `agent_core.service`
- log file: `/home/gameserver/GSP/agent_core.log`
- update source: configured Git repository, branch, and source path in `Cfg/bash_prefs.cfg`

Legacy names such as `agent_core_run` remain wrappers or protocol compatibility details only.

The repository identity is `GSE/Agent-Linux`, but installed-agent compatibility names remain `agent_core`, `/home/gameserver/GSP`, `gsp_` config keys, `X-GSP-*` headers, `GSP_*` screen names, and `WORKSHOP_*` job markers until the Panel and field installs are migrated together.

## Legacy Workshop RPC

The dedicated Panel `steam_workshop` module still uses the legacy `steam_workshop` XML-RPC call.

Current compatibility rule:

- if the Panel sends a blank `config_file_path`, the Linux agent runs post-install logic only
- the generated script must skip all `cat` / regex / config-write logic in that case
- `WorkshopModsInfo` is still written so the Panel can list/uninstall installed items even when no game config file is edited
- new installs write per-home records under `WorkshopModsInfo/home_<home_id>/`
- each record stores mod string, Workshop item ID, title, installed folder/path, Workshop App ID, install status, and timestamps
- the generated job writes `<game_home>/WorkshopInstallStatus.json` as `running`, `completed`, or `failed`
- the generated job prints `WORKSHOP_INSTALL_COMPLETE` or `WORKSHOP_INSTALL_FAILED` so the Panel can avoid stale `Update in progress` displays if the generic update screen lingers

## Server Content Hook Runtime

The Linux agent prepares this runtime layout for generated content hooks:

- `_game_content/hooks/`
- `_game_content/generated/`
- `_game_content/runtime/`
- `_game_content/runtime/server_content.pids`

During stop/restart, hook watchdog PIDs are cleaned up before hook application PIDs. Main game server watchdog PIDs should not be written to `server_content.pids`.

Legacy `_alsoRun.pid` files remain compatibility input only. When present at the game home root or one level below it, the Linux agent imports those PIDs into the server-content cleanup path so stop, restart, force-stop, and start preflight clean legacy helper processes consistently with the Windows agent.

The main game startup watchdog is regenerated as `<game_home>/serverStart.sh` on every Start and is launched directly by the named screen session. It records `<game_home>/watchdog.pid`, checks desired state every loop, supervises `game.pid` and optional `bot.pid` independently every 30 seconds, and treats a game exit within 120 seconds of launch as a crash loop: it writes `status.stopped`, terminates managed game/bot process groups, records a concise screen-log event, and exits. Optional bot configuration is read only from `<game_home>/bot.def`. Stop, force-stop, restart, and start preflight share the same Linux hard-stop helper: it writes `status.stopped`, stops the named screen, terminates watchdog, bot, and game PID trees/process groups, classifies TCP and UDP game-port owners, refuses protected or ambiguous owners, and removes stale PID/timestamp files only after verification.

For lifecycle RPCs, `home_path` is the server-ID `management_home`. Linux validates the XML `game_key` with the same safe-directory rules as the Panel, derives `game_root=<management_home>/<game_key>`, and resolves Start executable/run-directory, game logs, environment substitutions, and pre-start command substitutions beneath `game_root`. During the transition it accepts either `<game_key>/...` or game-root-relative run directories, but rejects unsafe keys, absolute paths, traversal, and paths escaping management home. Install/update destinations already supplied as payload paths remain payload paths, while generated install control scripts stay in the agent temp directory.

## Agent Operations RPCs

The Linux agent exposes these structured RPCs for the Admin -> Servers per-agent interface:

- `agent_version` returns OS, agent code build version, and install path. The code build version is used even when legacy config files still contain an old `version` value.
- `agent_resource_snapshot` returns CPU, RAM, disk, load average, OS, code build version, and install path for Panel-side caching.
- `server_status` keeps Linux-native process/session/port checks and returns shared readiness fields used by the Panel on both agents, including port-validation settings, expected/listening/missing ports, `CPUUsage`, `MemoryUsage`, `ProcessRunning`, `StatusState`, `linux_pid`, and compatibility aliases.
- `force_stop_server(home_id, server_ip, server_port, home_path)` removes the matching startup flag, writes `status.stopped`, runs the shared hard-stop helper, verifies session/process/port absence, and returns a structured result. Protected or ambiguous port owners are reported as actionable failures instead of being killed. It never restarts the game server.
- `agent_self_update(payload)` records a pending restart-time update request.
- `agent_update_status` returns the latest `agent_core_update_state.json` content.

## Installer Lifecycle

`install.sh` supports `install`, `repair`, `reconfigure`, and `uninstall`. Install and repair fetch the configured canonical Git repository and branch, validate the staged payload, copy source-owned files, and preserve customer/runtime state. The staged and installed payload must include the Linux SteamCMD bootstrap at `steamcmd/steamcmd.sh`; missing bootstrap files are restored into an installed `steamcmd/` directory without overwriting existing SteamCMD runtime state. Reconfigure regenerates local config only. Uninstall removes the managed systemd service and known source-owned agent files while preserving customer data by default; `--purge-data` is the explicit destructive path.

The agent does not run SteamCMD during startup, and non-Steam operations do not require SteamCMD or internet access. Steam-specific installs, updates, version checks, and Workshop operations validate `steamcmd/steamcmd.sh` when invoked and fail with a Steam-specific error if the bootstrap is unavailable.

## Self-Update And Rollback

The running agent never replaces its own files. The Panel sends an `agent_self_update` request with `component`, `repo_url`, `branch`, and `source_path`; the Linux agent validates those fields, writes `agent_core_update_request.json`, and records `pending` in `agent_core_update_state.json`.

Restart-time updates are local wrapper behavior, not Panel business logic. On the next normal service or foreground restart, `agent_core_run` checks `agent_auto_update=1` in `Cfg/bash_prefs.cfg` and the pending request. It stages the requested Git repo/branch/source path, validates `agent_core.pl` with `perl -c`, validates `agent_core_run` with `bash -n` when present, creates one local restart-update backup, copies staged files into place, records the result, and then starts the agent.

The restart-time update config keys are:

- `agent_auto_update`
- `agent_update_repo_url`
- `agent_update_branch`
- `agent_update_source_path`

The shared update state contract uses `pending`, `running`, `completed`, `failed`, and `rolled_back`. Terminal failures remove the pending request so a failed request does not retry on every restart without a new Panel request.

The updater preserves host/customer data and local config:

- `Cfg/`
- `ServerFiles/`
- `Schedule/`
- `logs/`
- `screenlogs/`
- `steamcmd/`
- `startups/`
- `runtime_status/`
- `events/`
- `tmp/`
- `shared/`
- PID files

Restart-time updates use the same SteamCMD preservation rule as install and repair: restore missing bundled bootstrap files only, preserve existing `steamcmd/` state, and never delete `steamapps/` or downloaded Workshop/content data.

If the updated agent does not listen on its RPC port before the timeout, the updater stops the failed instance, restores the backup, starts the previous agent, and records `rolled_back` or `failed` in `agent_core_update_state.json`.
