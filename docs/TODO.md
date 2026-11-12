# TODO and Issues

Read this file before you start work in this repo. Update it every time you work here.
The rules are in AGENTS.md under Work Tracking.

Type: todo, issue, goal, need.
Status: open, doing, done, invalid.
Older lists (for example docs/plans/BACKLOG.md) are copied into this file. Add new items only here.

| ID | Type | Status | Title | Owner | Opened | Updated | GitLab |
|---|---|---|---|---|---|---|---|
| T-001 | todo | open | Test restic job runner on Linux game hosts | Claude | 2026-11-05 | 2026-11-05 | - |
| T-002 | issue | open | No test yet for the no_supervisor path in restic jobs | Claude | 2026-11-05 | 2026-11-05 | - |
| T-003 | issue | open | Backup path check is a denylist; pin backup paths to home roots | Claude | 2026-11-05 | 2026-11-05 | - |
| T-004 | goal | open | Move docs/plans/BACKLOG.md items into this file | Claude | 2026-11-05 | 2026-11-05 | - |
| T-005 | issue | done | A dead watchdog is revived by a check every 30 seconds, like the Windows agent (reconcile_running_homes; tested on Ubuntu 24.04 2026-11-12) | Claude | 2026-11-12 | 2026-11-12 | - |
| T-006 | todo | open | Tested on the dev server (Ubuntu 24.04) with a fake game; still test on kclinux with a real game before release | Claude | 2026-11-12 | 2026-11-12 | - |
| T-007 | todo | open | Set the minimum Debian/Ubuntu release in requirements.json after testing on a host (kclinux was not reachable on 2026-11-12; Ubuntu 24.04 is being tested on the dev server) | Claude | 2026-11-12 | 2026-11-12 | - |
| T-008 | issue | open | install.sh in non-interactive mode retries a failed git clone forever; as root, git refuses the clone source with dubious ownership | Claude | 2026-11-12 | 2026-11-12 | - |
| T-009 | issue | open | Agent running as a non-sudo user logs sudo failures at start-up (su -c chmod/setfacl on screenlogs); harmless but noisy, and the permission fix does not happen | Claude | 2026-11-12 | 2026-11-12 | - |
| T-010 | issue | open | The watchdog stops the managed lifecycle (records STOPPED) when the game exits within 120 seconds of launch; confirm this crash-loop guard is wanted and shown in the Panel |  Claude | 2026-11-12 | 2026-11-12 | - |
| T-011 | issue | open | The agent does not exit promptly on SIGTERM: systemctl restart agent_core takes about 60 seconds (TimeoutStopSec) | Claude | 2026-11-12 | 2026-11-12 | - |
| T-012 | todo | open | Dev-server test setup to clean up when done: user gameserver and server_runner, sudoers file /etc/sudoers.d/gameserver-agent (dev only), test home /home/gameserver/GSP_homes/testhome with user gamehome9001, php8.3-xmlrpc, remote server 6 in panel-testing | Claude | 2026-11-12 | 2026-11-12 | - |
| T-013 | issue | open | Schedule::Cron here rebuilds its timetable every second (scheduler_read_tasks), so jobs with a seconds field other than every second never fire; new periodic jobs must ride the per-second task | Claude | 2026-11-12 | 2026-11-12 | - |

