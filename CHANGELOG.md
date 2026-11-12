# Changelog

Each fixed issue gets an entry under the version that shipped it: a one-line title, then the cause and the fix in plain language, written so a customer can follow it.

## 0.5.1
- **Agent stops at once:** `systemctl stop` and `restart` took 60 seconds because the start script ignored the stop signal and restarted the agent. It now passes the signal on and exits.
- **Installer:** a failed clone in non-interactive mode stops after 3 tries instead of retrying forever, and root can clone a source folder owned by another user. The prerequisite installer no longer exits at the i386 question when it has no keyboard (it takes the default, yes).
- **Requirements:** minimum is Ubuntu 22.04 or Debian 12 (tested in containers: the prerequisites install and the agent compiles).
- **A dead watchdog is brought back:** Every 30 seconds the agent checks each game that is wanted RUNNING. If its watchdog is gone (killed, or lost after a crash) it starts the watchdog again with `serverStart.sh start`. The watchdog takes over a game that is still up on its port (it is not killed), or launches it. A game wanted STOPPED is never touched, and each game is revived at most once a minute. Before this, the Panel showed OFFLINE or a warning while the status said RUNNING, until someone pressed Start.
- **Stop said "stopped" while the game kept running; Start then failed with the port in use:** When a game was left running without its watchdog (the watchdog was killed, or the agent restarted), the agent could not see the game. It runs as its own Linux user (`gamehomeNNN`), and the agent user cannot read that user's process details. So it did not find the game on its port, thought the game was dead, never killed it, and still reported success. The agent now looks up port owners and process details with sudo, treats a process it may not signal as alive, and counts a listening port as "still running" even when it cannot name the owner.
- **Kill really kills:** The agent's kill step sent `kill 15 <pid>`, which is not a TERM signal to that process, and ran as the wrong user when no screen session was left. It now sends TERM as root, waits up to 5 seconds, and then sends KILL.
- **Agent refused to start on a fresh install:** The start-up check for a missing agent key also matched the empty `web_admin_api_key` line in the default config, so a correctly configured agent was rejected as having a placeholder key. The check now only looks at the `key` line itself.
- **Start and stop on the host:** Each game folder now gets `startserver.sh` and `stopserver.sh`. They do the same as the Panel Start and Stop (they call `serverStart.sh start` or `stop`), so the status files stay correct when an admin starts or stops a game on the host. Closing the game by hand while it is wanted RUNNING still gets it restarted; use `stopserver.sh`.
- **Requirements file:** `requirements.json` lists the prerequisites for the website to show. Minimum is Ubuntu 22.04 or Debian 12; tested on Ubuntu 24.04 LTS with a game, and Ubuntu 22.04 and Debian 12 in containers.
- **One action at a time per server:** Start and Stop on the host take a per-server lock (`status.lock`), so two of them, or one with the Panel, cannot overlap and launch a second copy.
- **Status follows the real game:** The game port is now passed to the watchdog, which uses it to tell whether the game is really up, in the same way as the Windows agent. Tests: `tests/validate_status_follows_reality.sh`.

## 0.5.0
- **Agent version reported:** The Linux agent reports its version, 0.5.0. Commit `827496b`.
- **Deterministic game lifecycle:** Linux game start and stop now follow the same steps as the Windows agent. Commit `648092e`.
- **Restic backup job runner:** Added a secret-free backup runner. Its allowlist is limited to game folders, and restic is installed by the installer. Commits `a16307b`, `e048007`.
- **SteamCMD bootstrap bundled:** The Linux release includes the SteamCMD bootstrap. Commit `ccc859d`.
- **Release names:** Removed the old GSP, GSE and OGP prefixes from names. Commits `1b338f9`, `169673b`.
- **Release workflow:** One rolling working build, and a GitHub release per branch version. Commits `cab1b10`, `87c51c4`.
