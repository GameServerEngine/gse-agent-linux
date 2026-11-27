#!/usr/bin/env bash
# The update helper versus the supervisor loop (agent_core_run).
#
# What this guards against (seen on game5 and game6 on 2026-11-26): the helper stopped only the perl agent,
# the supervisor started it again ten seconds later, in the middle of the file copy, and the update was
# reported as successful while the agent was still running the old code.
#
# Everything runs in a temporary folder with a fake agent that logs which code version it loaded each time it
# starts. The helper signals every process on the host whose command line matches perl.*agent_core.pl, so this
# test refuses to run where a real agent is visible. On a host that has an agent, run it in a PID namespace:
#   sudo unshare --pid --fork --mount-proc sudo -u "$USER" -H bash tests/validate_update_helper_race.sh
#
# Scenarios (ONLY="S1 S3" runs a subset):
#   S1  supervisor without the hold (the version installed on the hosts today) + helper under test
#   S2  supervisor with the hold + helper under test
#   S3  helper under test with a wrong checksum: nothing may be left held, the agent must come back
#   S4  a hold left behind by a dead helper is ignored after 15 minutes
#   S5  a fresh hold keeps the supervisor from restarting the agent, and releasing it restarts the agent
#
# Overrides: HELPER_UNDER_TEST, SUPERVISOR_UNDER_TEST (to run an older copy and watch the old behaviour fail).

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${HELPER_UNDER_TEST:-$REPO/agent_update_helper.sh}"
NEW_SUPERVISOR="${SUPERVISOR_UNDER_TEST:-$REPO/agent_core_run}"
ONLY="${ONLY:-S1 S2 S3 S4 S5}"
PAD_FILES=120

for tool in python3 unzip flock perl ps sha256sum find pgrep setsid timeout; do
	command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not installed"; exit 0; }
done
if [ "$(id -u)" -eq 0 ]; then
	echo "SKIP: run as a normal user (agent_core_run refuses to run as root)"
	exit 0
fi
if pgrep -f 'perl.*agent_core\.pl' >/dev/null 2>&1; then
	echo "SKIP: a real agent is running on this host and the helper would signal it."
	echo "      Run in a PID namespace: sudo unshare --pid --fork --mount-proc sudo -u \"\$USER\" -H bash $0"
	exit 0
fi

failures=0
check() {
	if [ "$1" = "0" ]; then echo "ok - $2"; else echo "FAIL - $2"; failures=$((failures + 1)); fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gse-helper-race.XXXXXX")"
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"

# The helper copies one file per cp call. A short pause per call makes the copy long enough for a restart to
# land inside it, as it did on the real hosts.
cat > "$SHIMS/cp" <<'EOF'
#!/bin/sh
sleep 0.03
exec /bin/cp "$@"
EOF
# The helper's fallback start uses screen; run the command in the background instead.
cat > "$SHIMS/screen" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
	case "$1" in
		-d|-m) shift ;;
		-t|-S) shift 2 ;;
		*) break ;;
	esac
done
( setsid nohup "$@" >/dev/null 2>&1 & )
EOF
chmod +x "$SHIMS/cp" "$SHIMS/screen"

cleanup_all() {
	pkill -f "$TMP/" >/dev/null 2>&1 || true
	sleep 1
	rm -rf "$TMP"
}
trap cleanup_all EXIT

port_counter=0
next_port() { port_counter=$((port_counter + 1)); echo $((31900 + (RANDOM % 600) + port_counter)); }

# The fake agent: logs the code version it loaded, then waits. It does not trap TERM, so a stop looks like it
# does for the real agent (exit status 143, which the supervisor treats as a crash).
write_fake_agent() {
	cat > "$1/agent_core.pl" <<'EOF'
#!/usr/bin/perl
use strict; use warnings; use FindBin qw($Bin);
open(my $v, '<', "$Bin/CODE_VERSION") or die "no CODE_VERSION";
my $code = <$v>; chomp $code; close $v;
open(my $log, '>>', "$Bin/agent_starts.log") or die;
printf $log "%d start pid=%d code=%s\n", time, $$, $code;
close $log;
while (1) { sleep 1 }
EOF
}

# The supervisor as it is installed on the hosts today: restart after a non-zero exit, no update hold.
write_old_supervisor() {
	cat > "$1/agent_core_run" <<'EOF'
#!/usr/bin/env bash
AGENTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec 9>"$AGENTDIR/agent_core_run.lock"
flock -n 9 || exit 1
echo "$$" > "$AGENTDIR/agent_core_run.pid"
agent_pid=""
trap '[ -n "$agent_pid" ] && kill -TERM "$agent_pid" 2>/dev/null; exit 0' INT TERM
while true; do
	perl "$AGENTDIR/agent_core.pl" &
	agent_pid=$!
	wait "$agent_pid" || rc=$?
	agent_pid=""
	rc="${rc:-0}"
	[ "$rc" -eq 0 ] && exit 0
	sleep 2
	unset rc
done
EOF
}

make_sandbox() {	# name, supervisor kind (old|new)
	local dir="$TMP/$1/agent" kind="$2" port
	port="$(next_port)"
	mkdir -p "$dir/Cfg" "$dir/pad"
	printf 'package Cfg::Config;\nour %%Config = (key => "test-key", listen_ip => "127.0.0.1", listen_port => "%s");\n1;\n' "$port" > "$dir/Cfg/Config.pm"
	write_fake_agent "$dir"
	echo "v1" > "$dir/CODE_VERSION"
	for i in $(seq 1 "$PAD_FILES"); do echo "pad $i" > "$dir/pad/f$i"; done
	if [ "$kind" = "old" ]; then
		write_old_supervisor "$dir"
	else
		cp "$NEW_SUPERVISOR" "$dir/agent_core_run"
		sed -i 's/^TIMEOUT=10$/TIMEOUT=2/' "$dir/agent_core_run"
	fi
	chmod +x "$dir/agent_core_run" "$dir/agent_core.pl"
	echo "$dir"
}

start_supervisor() {
	( cd "$1" && setsid nohup bash ./agent_core_run -pidfile agent_core_run.pid >> supervisor.log 2>&1 & )
}

starts_count() { if [ -f "$1/agent_starts.log" ]; then wc -l < "$1/agent_starts.log" | tr -d ' '; else echo 0; fi; }
last_code() { if [ -f "$1/agent_starts.log" ]; then tail -n 1 "$1/agent_starts.log" | sed -E 's/.*code=//'; else echo none; fi; }
agents_running() { pgrep -fc "perl $1/agent_core\\.pl" 2>/dev/null || true; }

wait_for_starts() {	# dir, count, seconds
	local n=0
	while [ "$n" -lt "$3" ]; do
		[ "$(starts_count "$1")" -ge "$2" ] && return 0
		sleep 1; n=$((n + 1))
	done
	return 1
}

make_release() {	# name, dir
	local zip="$TMP/$1/release.zip"
	python3 - "$zip" "$2" "$NEW_SUPERVISOR" "$PAD_FILES" <<'PY'
import sys, zipfile
zip_path, agent_dir, supervisor, pad = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
top = "gse-agent-linux-testing-9.9.9/"
with zipfile.ZipFile(zip_path, "w") as z:
    z.writestr(top + "CODE_VERSION", "v2\n")
    with open(agent_dir + "/agent_core.pl") as f:
        z.writestr(top + "agent_core.pl", f.read())
    with open(supervisor) as f:
        z.writestr(top + "agent_core_run", f.read())
    for i in range(1, pad + 1):
        z.writestr(top + "pad/f%d" % i, "new pad %d\n" % i)
PY
	echo "$zip"
}

run_helper() {	# dir, zip, sha
	( cd "$1" && PATH="$SHIMS:$PATH" GSE_UPDATE_SETTLE_SECONDS=1 GSE_UPDATE_POLL_SECONDS=1 GSE_UPDATE_STABLE_SECONDS=3 \
		timeout 300 bash "$HELPER" --agent-dir "$1" --zip "$2" --sha256 "$3" --version testing-9.9.9 --agent-pid 0 \
		--service-name no_such_unit --state-file "$1/update_state.json" --log-file "$1/update.log" >> "$1/helper.out" 2>&1 )
}

state_status() { sed -nE 's/.*"status":"([a-z_]+)".*/\1/p' "$1/update_state.json" 2>/dev/null | head -n 1; }

stop_sandbox() {
	local dir="$1"
	[ -f "$dir/agent_core_run.pid" ] && kill -TERM "$(cat "$dir/agent_core_run.pid")" 2>/dev/null || true
	pkill -f "perl $dir/agent_core\\.pl" 2>/dev/null || true
	sleep 1
}

scenario_update() {	# name, supervisor kind
	local name="$1" kind="$2" dir zip sha rc
	echo "--- $name"
	dir="$(make_sandbox "$name" "$kind")"
	start_supervisor "$dir"
	wait_for_starts "$dir" 1 20; check $? "$name: the fake agent started (v1)"
	zip="$(make_release "$name" "$dir")"
	sha="$(sha256sum "$zip" | cut -d' ' -f1)"
	run_helper "$dir" "$zip" "$sha"; rc=$?
	check "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "$name: the helper finished successfully (exit $rc)"
	check "$([ "$(state_status "$dir")" = "ok" ] && echo 0 || echo 1)" "$name: the recorded state is ok (is '$(state_status "$dir")')"
	check "$([ "$(last_code "$dir")" = "v2" ] && echo 0 || echo 1)" "$name: the agent that is running loaded the NEW code (loaded '$(last_code "$dir")')"
	check "$([ "$(agents_running "$dir")" = "1" ] && echo 0 || echo 1)" "$name: exactly one agent is running ($(agents_running "$dir"))"
	check "$([ ! -e "$dir/agent_update_hold" ] && echo 0 || echo 1)" "$name: no update hold is left behind"
	if [ "$kind" = "new" ]; then
		check "$([ "$(starts_count "$dir")" = "2" ] && echo 0 || echo 1)" "$name: the agent started exactly twice, before and after the update ($(starts_count "$dir"))"
	else
		echo "     (starts: $(starts_count "$dir"); helper log mentions the stale agent: $(grep -c 'before the new files were in place' "$dir/update.log" 2>/dev/null))"
	fi
	stop_sandbox "$dir"
}

scenario_bad_checksum() {
	local name="S3" dir zip rc
	echo "--- $name"
	dir="$(make_sandbox "$name" new)"
	start_supervisor "$dir"
	wait_for_starts "$dir" 1 20; check $? "$name: the fake agent started (v1)"
	zip="$(make_release "$name" "$dir")"
	run_helper "$dir" "$zip" "0000000000000000000000000000000000000000000000000000000000000000"; rc=$?
	check "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "$name: the helper refuses a wrong checksum (exit $rc)"
	check "$([ ! -e "$dir/agent_update_hold" ] && echo 0 || echo 1)" "$name: no update hold is left behind"
	wait_for_starts "$dir" 2 30; check $? "$name: the agent came back after the failed update"
	check "$([ "$(last_code "$dir")" = "v1" ] && echo 0 || echo 1)" "$name: it is still the old code, nothing was replaced (is '$(last_code "$dir")')"
	stop_sandbox "$dir"
}

scenario_expired_hold() {
	local name="S4" dir
	echo "--- $name"
	dir="$(make_sandbox "$name" new)"
	: > "$dir/agent_update_hold"
	touch -d '20 minutes ago' "$dir/agent_update_hold"
	start_supervisor "$dir"
	wait_for_starts "$dir" 1 20; check $? "$name: the agent started although an old hold was present"
	check "$([ ! -e "$dir/agent_update_hold" ] && echo 0 || echo 1)" "$name: the expired hold was removed"
	stop_sandbox "$dir"
}

scenario_hold_blocks_restart() {
	local name="S5" dir
	echo "--- $name"
	dir="$(make_sandbox "$name" new)"
	start_supervisor "$dir"
	wait_for_starts "$dir" 1 20; check $? "$name: the agent started"
	: > "$dir/agent_update_hold"
	pkill -f "perl $dir/agent_core\\.pl" 2>/dev/null || true
	sleep 7
	check "$([ "$(starts_count "$dir")" = "1" ] && echo 0 || echo 1)" "$name: with a hold in place the agent was not restarted ($(starts_count "$dir") start)"
	rm -f "$dir/agent_update_hold"
	wait_for_starts "$dir" 2 15; check $? "$name: once the hold was released the agent started again"
	stop_sandbox "$dir"
}

for s in $ONLY; do
	case "$s" in
		S1) scenario_update S1 old ;;
		S2) scenario_update S2 new ;;
		S3) scenario_bad_checksum ;;
		S4) scenario_expired_hold ;;
		S5) scenario_hold_blocks_restart ;;
	esac
done

echo
if [ "$failures" -eq 0 ]; then echo "Update helper race checks passed."; else echo "$failures update helper race check(s) FAILED."; fi
exit $((failures > 0 ? 1 : 0))
