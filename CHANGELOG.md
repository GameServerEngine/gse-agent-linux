# Changelog

Each fixed issue gets an entry under the version that shipped it: a one-line title, then the cause and the fix in plain language, written so a customer can follow it.

## 0.5.1
- **Start and stop on the host:** Each game folder now gets `startserver.sh` and `stopserver.sh`. They do the same as the Panel Start and Stop (they call `serverStart.sh start` or `stop`), so the status files stay correct when an admin starts or stops a game on the host. Closing the game by hand while it is wanted RUNNING still gets it restarted; use `stopserver.sh`.
- **Requirements file:** `requirements.json` lists the prerequisites for the website to show. The minimum Debian and Ubuntu release is still to be set.
- **One action at a time per server:** Start and Stop on the host take a per-server lock (`status.lock`), so two of them, or one with the Panel, cannot overlap and launch a second copy.
- **Status follows the real game:** The game port is now passed to the watchdog, which uses it to tell whether the game is really up, in the same way as the Windows agent. Tests: `tests/validate_status_follows_reality.sh`.

## 0.5.0
- **Agent version reported:** The Linux agent reports its version, 0.5.0. Commit `827496b`.
- **Deterministic game lifecycle:** Linux game start and stop now follow the same steps as the Windows agent. Commit `648092e`.
- **Restic backup job runner:** Added a secret-free backup runner. Its allowlist is limited to game folders, and restic is installed by the installer. Commits `a16307b`, `e048007`.
- **SteamCMD bootstrap bundled:** The Linux release includes the SteamCMD bootstrap. Commit `ccc859d`.
- **Release names:** Removed the old GSP, GSE and OGP prefixes from names. Commits `1b338f9`, `169673b`.
- **Release workflow:** One rolling working build, and a GitHub release per branch version. Commits `cab1b10`, `87c51c4`.
