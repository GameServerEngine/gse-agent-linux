# GSE Linux Game Server Lifecycle Contract

This document is the durable Linux inspection and handoff record for the
cross-platform game-server lifecycle contract. It reconciles the current Linux
implementation with the Windows lifecycle specification and the Panel workflow
contract inspected on 2026-07-27.

Linux must expose the same lifecycle semantics as Windows and Panel. Only the
mechanics differ: Linux uses `screen`, shell PID capture, signals, `/proc`, and
Linux TCP/UDP owner tools instead of Windows batch, PowerShell, and `taskkill`.

## Scope

This contract covers Start, Stop, Force Stop, Restart, automatic startup replay,
runtime status, watchdog supervision, optional bot supervision, Server Content
hook cleanup, generated management files, and the game-key payload boundary.

No migration tooling is in scope. Existing homes are rearranged manually by the
operator before enabling the new layout.

## Authoritative Layout

`management_home` is the server-ID directory assigned to one managed game
server. `game_root` is a child directory beneath it named from the validated XML
`game_key`:

```text
management_home/<validated game_key>
```

The `game_key` must be validated before path construction. It is one safe path
segment only: not empty, no surrounding whitespace, no traversal, no slash or
backslash, no drive prefix or colon, no control characters, no reserved device
names, only ASCII letters, digits, dot, underscore, and dash, no trailing dot,
and no resolved path escaping `management_home`.

Game payload belongs under `game_root`: game executable, install/update payload,
game configs, mods, missions, saves, Workshop payload, and user content. GSP
management artifacts belong in `management_home` or agent-root runtime
directories, never beneath `game_root`.

Linux Start derives `game_root` from `management_home` and the XML `game_key`
inside the agent before resolving the executable working directory. During the
Panel transition the agent accepts both `run_dir=<game_key>/...` and
`run_dir=...`; both resolve to the same path beneath `game_root`. A Start with
an invalid key, missing game root, absolute run directory, traversal, or a path
escaping `game_root` fails before watchdog generation.

Management artifacts that must not be created beneath `game_root` include
watchdog scripts, status markers, PID files, bot definitions, runtime metadata,
Server Content management directories, screen logs, and lifecycle-only logs.

## Desired State

The authoritative desired state is exactly one marker in `management_home`:

| File | Meaning |
| --- | --- |
| `status.running` | The Panel and agent intend this home to be running. |
| `status.stopped` | The Panel and agent intend this home to be stopped. |

Desired state is intent only. It is not proof that a process exists or that a
port is listening. Missing, duplicate, conflicting, unreadable, or invalid
desired-state markers fail safe as stopped.

Required transitions:

| Operation | Desired-state behavior |
| --- | --- |
| Start | Write stopped during preflight cleanup, then replace with only `status.running` immediately before launching the watchdog. |
| Stop | Replace with only `status.stopped` before killing anything. |
| Force Stop | Replace with only `status.stopped` before killing anything. |
| Restart | Verified Stop first, then fresh Start. |
| Watchdog crash loop | Replace with only `status.stopped`, clean managed processes, and exit. |

The current Linux implementation writes `status.running` and `status.stopped`
in `management_home` through `write_desired_state_without_decrypt`. Legacy
`startups/status-<home_id>` hint helpers remain only so stale files can be
removed during verified cleanup; active Start, Stop, Force Stop, Restart, and
status classification no longer use them as lifecycle control state.

## Actual State

Actual runtime state must be proven from live evidence:

- exact screen session `GSP_HOME_<home_id zero-padded to 9 digits>`
- `watchdog.pid`
- `bot.pid`, when a bot is configured or has been launched
- `game.pid`
- TCP and UDP owners of the assigned game port
- temporary compatibility PID metadata from `runtime_status/pid-<home_id>.kv`
- temporary compatibility Server Content PID records

Status and cleanup must not treat desired-state markers, automatic-start
records, or legacy status hints as proof of actual runtime.

## Current Linux Implementation Map

The current Linux lifecycle is concentrated in `gsp_agent.pl`.

| Concern | Current evidence |
| --- | --- |
| Agent-root runtime constants | `GAME_STARTUP_DIR` is `startups/`, `SERVER_RUNTIME_DIR` is `runtime_status/`, `SCREEN_LOGS_DIR` is `screenlogs/`, and `SCREENRC_FILE` is `gsp_screenrc` near lines 95-112. |
| Server Content runtime | `prepare_server_content_runtime_without_decrypt` creates `_gsp_content/hooks`, `_gsp_content/generated`, `_gsp_content/runtime`, and `_gsp_content/runtime/server_content.pids` under the current home path near lines 219-237. |
| Legacy helper PID import | `import_legacy_also_run_pids_without_decrypt` reads `_alsoRun.pid` at the home root and one level below, then imports PIDs into `server_content.pids` near lines 252-276. |
| Server Content cleanup | `cleanup_server_content_hooks_without_decrypt` kills `watchdog` role PIDs before `app` role PIDs near lines 321-330. |
| Automatic startup replay | Agent startup reads `startups/<ip>-<port>` records and skips `status-`/`pid-` marker-like files near lines 616-696. |
| Screen naming | `create_screen_id` returns `GSP_<type>_<home_id>` zero-padded to 9 digits near lines 973-977. |
| Screen launch command | `create_screen_cmd_loop` launches `screen -d -m ... -S <screen_id> bash <management_home>/serverStart.sh`; no generated launch wrapper is in the active path. |
| Current generated watchdog | `create_screen_cmd_loop` writes one readable `serverStart.sh` in `management_home` on every Start. |
| Current watchdog loop | The generated shell exits unless `status.running` is readable and `status.stopped` is absent, checks every 30 seconds, reads `game.pid` and `game.launch_ts`, relaunches the game only when crash-loop policy allows it, reads optional `bot.def`, and manages `bot.pid` independently. |
| Current watchdog PID | The watchdog writes `watchdog.pid` under the current management home. |
| Current Start | `universal_start_without_decrypt` invokes `hard_stop_server_without_decrypt` as stopped-state preflight before writing `startups/<ip>-<port>`, prepares runtime, generates the watchdog command, writes `status.running`, launches screen, then writes `runtime_status/pid-<home_id>.kv`. |
| Current Stop | `stop_server_without_decrypt` delegates to `hard_stop_server_without_decrypt`, which writes `status.stopped`, removes the startup flag, cleans Server Content hooks, quits screen, kills `watchdog.pid`, `bot.pid`, `game.pid`, classifies and kills safe TCP/UDP port owners, and verifies. |
| Current verification | `verify_runtime_stop_complete_without_decrypt` and the shared hard-stop helper verify screen absence, tracked PID absence, and TCP/UDP game-port owner absence, then remove stale PID/timestamp/status-hint files after success. |
| Current Force Stop | `force_stop_server_without_decrypt` validates target, delegates to the shared hard-stop helper, and returns structured success or protected/ambiguous/cleanup failure evidence. |
| Current Restart | `restart_server_without_decrypt` calls Stop, waits 60 seconds, verifies old runtime is stopped, then calls Start near lines 4804-4881. |
| Current status | `server_status_without_decrypt` combines screen, metadata PIDs, and port evidence; legacy status hints are not active status input. |
| Current port owner lookup | `find_process_pids_by_port_without_decrypt` checks TCP and UDP via `lsof` and `ss`, returns all discovered owner PIDs, and hard-stop classification refuses protected or ambiguous owners. |
| Current port listening check | `is_port_listening_without_decrypt` checks TCP/UDP via `ss`, `netstat`, and `lsof` near lines 1465-1495. |
| Current home PID cleanup | `kill_home_pid_files_without_decrypt` reads and removes `watchdog.pid`, `bot.pid`, and `game.pid` near lines 1401-1422. |
| Current game-key path helpers | `validate_game_key_without_decrypt`, `resolve_game_root_without_decrypt`, and `resolve_game_payload_path_without_decrypt` mirror the Panel helper rules and keep Start payload paths beneath `management_home/<game_key>`. |

## Generated Management Artifacts

The current Linux code creates or consumes these lifecycle-related artifacts.

| Artifact | Current location | Target status |
| --- | --- | --- |
| `serverStart.sh` | `management_home` | Keep as the one regenerated readable watchdog script directly owned by the named screen. |
| `GSP_HOME_<id>_startup_scr.sh` | Legacy agent current directory at Start time | Cleanup-only obsolete file; new Starts do not generate it. |
| `startups/<ip>-<port>` | Agent root | Keep only as persistent automatic-start registration. It is not desired state or actual state. |
| `startups/status-<home_id>` | Agent root | Legacy cleanup-only file. Active lifecycle paths no longer write or read it. |
| `runtime_status/pid-<home_id>.kv` | Agent root | Temporary compatibility status/cleanup reader only until direct PID evidence is authoritative. |
| `screenlogs/screenlog.GSP_HOME_<id>` | Agent root | Keep outside `game_root`. |
| `watchdog.pid` | Current management home | Keep in `management_home`; kill before bot/game. |
| `bot.pid` | Current home path | Keep in `management_home`; kill before game after watchdog/screen are targeted. |
| `game.pid` | Current home path | Keep in `management_home`. |
| `bot.def` | `management_home` | Optional current bot definition with working directory, executable or command, and arguments. |
| `_alsoRun.cmd` | Legacy home path | Compatibility reader only during cleanup/transition; new Starts do not read or generate it. |
| `_alsoRun.pid` | Home root or one level below | Compatibility cleanup reader only. |
| `_alsoRun.bat` | Home path cleanup target | Do not generate; cleanup-only stale file. |
| `_gsp_content/hooks` | Current home path | Must live under `management_home`, not `game_root`. |
| `_gsp_content/generated` | Current home path | Must live under `management_home`, not `game_root`. |
| `_gsp_content/runtime/server_content.pids` | Current home path | Keep as management PID registry under `management_home`; never store main game watchdog/game PIDs here. |
| `prestart_ogp.sh` | Current home path from `run_before_start_commands` | Management script; keep in `management_home` or replace with a safer generated name there. |
| `secure.sh`, `preinstall.sh`, `postinstall.sh`, `runinstall.sh` | Agent temp `tmp/home_id_<home_id>/` for update/install jobs | Management scripts; do not write them into game payload roots. |

Legacy files no longer generated by the active Start path:

- `GSP_HOME_<id>_startup_scr.sh` as an agent-root watchdog
- `_alsoRun.cmd` as the active bot definition
- `_alsoRun.bat`
- `startups/status-<home_id>`
- any `STARTING`, `STOPPING`, `FORCE_STOPPING`, or `STOPPED` hint as active
  lifecycle state
- any management-only `_gsp_content` directory beneath `game_root`

Temporary cleanup-only compatibility readers:

- `_alsoRun.pid`
- old `_alsoRun.cmd`
- old `watchdog.pid`, `bot.pid`, and `game.pid` from a former home layout
- `runtime_status/pid-<home_id>.kv`
- `startups/status-<home_id>`
- existing `_gsp_content/runtime/server_content.pids`

Compatibility readers must not recreate legacy files or treat them as primary
state.

## Start Contract

Every Start must regenerate the watchdog from current resolved values supplied
by the Panel:

- `management_home`
- validated `game_key`
- `game_root`
- executable
- run directory
- arguments
- environment variables
- assigned IP and game port
- CPU/nice settings
- pre-start commands
- replace-text results
- optional bot working directory, executable or command, and arguments

Required Linux Start preflight:

1. Validate `home_id`, `management_home`, `game_key`, `game_root`, assigned IP,
   and assigned port.
2. Write desired state as stopped.
3. Remove stale desired-state conflicts and safe stale runtime files.
4. Terminate the exact managed screen session if present.
5. Kill tracked watchdog process tree.
6. Kill tracked bot process tree.
7. Kill tracked game process tree.
8. Read cleanup-only legacy PID sources and kill safe matching processes.
9. Resolve TCP and UDP owners of the anticipated assigned game port.
10. Kill safe matching port owners.
11. Refuse Start if a protected or ambiguous process owns the port.
12. Verify the screen, tracked PIDs, and TCP/UDP port owners are absent.
13. Regenerate one readable watchdog in `management_home`.
14. Regenerate the optional bot definition in `management_home` when configured.
15. Write desired state as running.
16. Launch one watchdog directly inside one named screen session.

Automatic startup replay only starts homes whose persisted startup registration
is paired with a valid `status.running` marker in `management_home`. Missing,
conflicting, unreadable, invalid, or stopped markers are skipped, so an agent
restart cannot revive a home that Stop, Force Stop, or crash-loop shutdown
marked stopped.

Linux screen launch target:

```text
screen -d -m -t "GSP_HOME_<id>" -c <screenrc> -S GSP_HOME_<id> bash <management_home>/serverStart.sh
```

No extra generated screen-launch wrapper should remain in the active path.

## Watchdog Contract

The generated Linux watchdog is short and readable from top to bottom.

Required behavior:

1. Write its PID or process-group identifier to `watchdog.pid`.
2. Loop only while `status.running` exists and `status.stopped` does not.
3. Check every 30 seconds.
4. Verify `game.pid`.
5. If the game is absent, compare the prior game launch timestamp with current
   time before relaunch.
6. Launch the game from the resolved game working directory, capture the correct
   PID/process group, and write `game.pid` plus `game.launch_ts`.
7. Verify optional `bot.pid` independently.
8. Launch the bot from its configured working directory and write `bot.pid`.
9. Return to `management_home` after any game or bot launch.

If the game dies less than 120 seconds after its last launch, the watchdog must
write stopped desired state, prevent relaunch, clean all managed processes, log
or emit concise crash-loop evidence, and exit so the screen ends. A missing bot
restarts independently and must not restart or stop a healthy game.

## Hard Stop Contract

Stop and Force Stop must share one Linux hard-stop implementation. Restart must
be exactly verified hard stop followed by fresh Start.

Hard-stop order:

1. Validate `home_id`, `management_home`, assigned IP, and assigned port.
2. Write `status.stopped` before killing anything.
3. Remove persistent automatic-start registration for `<ip>-<port>` when the
   operation means the server should not auto-start.
4. Stop the exact named screen session.
5. Kill the `watchdog.pid` process tree.
6. Kill the `bot.pid` process tree.
7. Kill the `game.pid` process tree.
8. Read and clean compatibility PID sources.
9. Resolve TCP and UDP owners for the assigned game port.
10. Kill safe matching port owners.
11. Verify the exact screen is absent.
12. Verify tracked PIDs are absent.
13. Verify no safe process owns the assigned TCP or UDP port.
14. Remove stale PID/timestamp/runtime files only after verification.

Stop may attempt a configured graceful control-protocol shutdown only when it
cannot race with watchdog relaunch and cannot weaken final verification. Force
Stop skips graceful control-protocol shutdown and performs hard stop directly.

## Protected Process Rules

Linux lifecycle cleanup must never kill:

- PID `0` or PID `1`
- kernel threads
- the running agent process or its parent process tree
- SSH, networking, init, system service, and package manager infrastructure
- unrelated `screen`, shell, Perl, or sudo processes that cannot be attributed
  to the selected home
- any process whose executable path, command line, owner, parentage, or port
  evidence cannot be safely associated with `management_home`, `game_root`, a
  tracked PID tree, a compatibility PID source, or the assigned port cleanup
  policy

If a protected or ambiguous process owns the assigned port, Start, Stop, Force
Stop, and Restart must return an actionable failure instead of killing it.

## Port Owner Cleanup

Both TCP and UDP owners of the assigned game port must be checked. Linux may use
`ss`, `lsof`, `/proc`, and other native read-only inspection tools to identify
owners. A process is safe to kill only when it is associated with the selected
home by tracked PID ancestry, executable or command path under
`management_home` or `game_root`, a compatibility PID source, or another
explicitly documented safe ownership rule.

The current implementation enumerates TCP and UDP owners returned by `lsof` and
`ss`, then classifies each owner as safe, protected, or ambiguous before any
termination attempt.

## Status And Verification

`server_status` must report desired state separately from actual evidence.
Externally visible status should converge with the Windows/Panel contract:

- `Stopped`: desired stopped or invalid, with no screen, tracked process, or
  assigned port owner.
- `Starting`: desired running and process/screen evidence exists, but required
  ports are not ready.
- `Running`: desired running and expected process/port evidence is present.
- `Warning`: conflicting actual evidence exists, such as assigned port owner
  without managed screen or tracked PID evidence.
- `Failed`: desired running but verification fails after timeout, or protected
  or ambiguous ownership blocks cleanup.

Stop, Force Stop, and Restart success requires verification that the named
screen, watchdog, bot, game, and assigned TCP/UDP port owners are inactive.

## Platform-Specific Difference

Windows may use PowerShell only for reliable process launch PID capture and
TCP/UDP owner discovery, then `taskkill /PID <pid> /T /F` for known trees.
Linux must use native process mechanics: shell PID capture, process groups,
signals, `/proc`/process inspection, and Linux port-owner tools. The returned
contract and filenames remain the same.

## Repositories Reconciled

- Linux: `/home/dev/Projects/GSE-Agent-Linux`
- Windows: `/home/dev/Projects/GSE-Agent-Windows`
- Panel: `/home/dev/Projects/GSE-Panel`

Windows contract source:
`/home/dev/Projects/GSE-Agent-Windows/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`.

Panel workflow source:
`/home/dev/Projects/GSE-Panel/.devplus/workspaces/panel-game-lifecycle-layout-20260727/WORKFLOW.md`.

## Post-Deployment Linux Smoke Test

Run this bounded smoke test on one non-production Linux host after deploying the
coordinated Panel, Windows, and Linux lifecycle release:

1. Create a new disposable home with `management_home=/home/gameserver/GSP/ServerFiles/<id>` and `game_root=<management_home>/<game_key>`.
2. Install or copy a tiny test server payload under `game_root`; leave `management_home` containing only management artifacts.
3. Start from the Panel and verify exactly one `serverStart.sh`, one `watchdog.pid`, one `game.pid`, and one `status.running` exist in `management_home`, while none of those files exist beneath `game_root`.
4. Change a launch option and Start or Restart again; verify `serverStart.sh` timestamp/content changes and only one named `GSP_HOME_<id>` screen remains.
5. Bind the assigned TCP and UDP port with disposable processes under the same test home, then Start; verify preflight kills those safe owners before launch.
6. Bind the assigned port with an unrelated protected or ambiguous process and confirm Start/Force Stop returns a structured failure without killing it.
7. Stop, Force Stop, and Restart from the Panel; after each terminal stop state verify the screen, watchdog, game, optional bot, and TCP/UDP port owners are absent.
8. Simulate a game process exiting before 120 seconds and verify the watchdog writes `status.stopped`, cleans managed processes, and exits; restart the agent and confirm the stopped home is not auto-started.
9. Simulate a game process exiting after 120 seconds and verify the watchdog relaunches the game without restarting a healthy optional bot.
10. Capture `server_status` after each action and verify desired state, process evidence, session evidence, and port evidence match the Windows/Panel contract.
