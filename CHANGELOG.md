# Changelog

Each fixed issue gets an entry under the version that shipped it: a one-line title, then the cause and the fix in plain language, written so a customer can follow it.

## 0.5.0
- **Agent version reported:** The Linux agent reports its version, 0.5.0. Commit `827496b`.
- **Deterministic game lifecycle:** Linux game start and stop now follow the same steps as the Windows agent. Commit `648092e`.
- **Restic backup job runner:** Added a secret-free backup runner. Its allowlist is limited to game folders, and restic is installed by the installer. Commits `a16307b`, `e048007`.
- **SteamCMD bootstrap bundled:** The Linux release includes the SteamCMD bootstrap. Commit `ccc859d`.
- **Release names:** Removed the old GSP, GSE and OGP prefixes from names. Commits `1b338f9`, `169673b`.
- **Release workflow:** One rolling working build, and a GitHub release per branch version. Commits `cab1b10`, `87c51c4`.
