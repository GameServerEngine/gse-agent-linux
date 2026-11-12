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
| T-007 | todo | done | Set the minimum Debian/Ubuntu release in requirements.json after testing on a host (kclinux was not reachable on 2026-11-12; Ubuntu 24.04 is being tested on the dev server) -- Set 2026-11-12: Ubuntu 22.04 / Debian 12 minimum, from container tests of the prerequisites and a compile check | Claude | 2026-11-12 | 2026-11-12 | - |
| T-008 | issue | done | install.sh in non-interactive mode retries a failed git clone forever; as root, git refuses the clone source with dubious ownership -- Fixed 2026-11-12: git clone uses safe.directory, and non-interactive mode gives up after 3 tries | Claude | 2026-11-12 | 2026-11-12 | - |
| T-009 | issue | open | Agent running as a non-sudo user logs sudo failures at start-up (su -c chmod/setfacl on screenlogs); harmless but noisy, and the permission fix does not happen | Claude | 2026-11-12 | 2026-11-12 | - |
| T-010 | issue | open | The watchdog stops the managed lifecycle (records STOPPED) when the game exits within 120 seconds of launch; confirm this crash-loop guard is wanted and shown in the Panel |  Claude | 2026-11-12 | 2026-11-12 | - |
| T-011 | issue | done | The agent does not exit promptly on SIGTERM: systemctl restart agent_core takes about 60 seconds (TimeoutStopSec) -- Fixed 2026-11-12: the TERM trap in agent_core_run now stops the agent and exits; stop and restart take under 1 second | Claude | 2026-11-12 | 2026-11-12 | - |
| T-012 | note | done | KEEP the dev-server test setup as the permanent Linux test fixture (not to be cleaned up): user gameserver and server_runner, /etc/sudoers.d/gameserver-agent (dev only), agent in /home/gameserver/GSP, test home /home/gameserver/GSP_homes/testhome (home 9001, port 27990, user gamehome9001), php8.3-xmlrpc, remote server 6 (devops-test) in the panel-testing database. Never copy the sudoers file to a customer host | Claude | 2026-11-12 | 2026-11-12 | - |
| T-013 | issue | open | Schedule::Cron here rebuilds its timetable every second (scheduler_read_tasks), so jobs with a seconds field other than every second never fire; new periodic jobs must ride the per-second task | Claude | 2026-11-12 | 2026-11-12 | - |
| T-014 | todo | done | Games started by the agent must survive an agent stop or restart. Verified on Ubuntu 24.04 2026-11-12: the agent starts games through sudo su, so each game and its watchdog run in their own login session (user-1008.slice), outside the agent's systemd unit. systemctl stop, then start, kept the same game pid, watchdog and open port, and the status stayed ONLINE. KillMode=process was tried and rejected: it leaves the scheduler process running | Claude | 2026-11-12 | 2026-11-12 | - |
| T-015 | issue | open | testing-0.5.2 (the newest testing release) predates the fixes on working (web_admin_api_key start check, i386 prompt, ip discovery). gse-agent-linux-install.sh works with it (it answers the prompt and leaves web_admin_api_key out), but the IP list stays empty until a release with b24cc26 is out. Merge working into testing. | open | | |
| T-016 | issue | open | agent_self_update takes only a git repo_url and branch; the panel Update page sends a release archive_url, so panel updates of Linux agents fail. Port the Windows archive update. | open | | |
