#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent="$repo_root/gsp_agent.pl"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

require_text() {
	local pattern="$1"
	grep -Fq -- "$pattern" "$agent" || fail "missing watchdog contract source: $pattern"
}

require_text 'desired_state_paths_without_decrypt'
require_text 'write_desired_state_without_decrypt'
require_text 'read_desired_state_without_decrypt'
require_text 'hard_stop_server_without_decrypt'
require_text 'safe_port_owner_status_without_decrypt'
require_text 'find_process_pids_by_port_without_decrypt'
require_text 'my $server_start_bashfile = "$home_path/serverStart.sh";'
require_text 'my $screen_exec_script = "bash " . $quoted_watchdog_path;'
require_text 'is_running_state()'
require_text '[ -r "$HOME_PATH/status.running" ] && [ ! -e "$HOME_PATH/status.stopped" ]'
require_text 'echo "$$" > "$HOME_PATH/watchdog.pid"'
require_text 'load_bot_definition()'
require_text '[ -r "$HOME_PATH/bot.def" ] || return 0'
require_text 'sleep 30'
require_text 'game.launch_ts'
require_text '-lt 120'
require_text 'publish_stopped_state'
require_text 'cleanup_managed_processes'
require_text 'setsid bash -lc "exec $GAME_COMMAND"'
require_text 'terminate_pid_group()'
require_text 'proc_process_group_id_without_decrypt'
require_text 'process_group_pids_without_decrypt'
require_text 'foreach my $pid_name ("watchdog.pid", "bot.pid", "game.pid")'
require_text 'clear_lifecycle_runtime_files_without_decrypt($home_id, $home_path);'
require_text 'my $preflight = hard_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path, remove_startup => 0, preflight => 1);'
require_text 'my $stop = hard_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path, remove_startup => 1);'
require_text 'my $hard_stop = hard_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path, remove_startup => 1, force => 1);'
require_text 'status => $success ? '\''STOPPED'\'' : $hard_stop->{status}'

line_for() {
	local pattern="$1"
	local line
	line="$(grep -nF -- "$pattern" "$agent" | head -n 1 | cut -d: -f1)"
	[ -n "$line" ] || fail "missing ordered watchdog contract source: $pattern"
	printf '%s\n' "$line"
}

require_order() {
	local before_label="$1"
	local before_pattern="$2"
	local after_label="$3"
	local after_pattern="$4"
	local before_line
	local after_line
	before_line="$(line_for "$before_pattern")"
	after_line="$(line_for "$after_pattern")"
	[ "$before_line" -lt "$after_line" ] || fail "$before_label must appear before $after_label"
}

running_state_calls="$(
	grep -F 'is_running_state' "$agent" | wc -l | tr -d '[:space:]'
)"
[ "$running_state_calls" -ge 5 ] || fail "expected generated watchdog state checks, found $running_state_calls"

require_order "serverStart path" 'my $server_start_bashfile = "$home_path/serverStart.sh";' "watchdog script open" "open (SERV_START_SCRIPT, '>', \$server_start_bashfile);"
require_order "watchdog PID capture" 'echo "$$" > "$HOME_PATH/watchdog.pid"' "running state function" 'is_running_state()'
require_order "running state function" 'is_running_state()' "game launch" 'setsid bash -lc "exec $GAME_COMMAND"'
require_order "game launch timestamp" 'date +%s > "$HOME_PATH/game.launch_ts"' "main loop" 'while is_running_state; do'
require_order "crash-loop event" 'game exited within 120 seconds; stopping managed lifecycle' "crash-loop stopped state" '            publish_stopped_state'
require_order "bot definition load" 'load_bot_definition()' "bot launch" 'launch_bot()'
require_order "start preflight" 'my $preflight = hard_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path, remove_startup => 0, preflight => 1);' "startup flag creation" '# Create startup file for the server.'
require_order "stop hard stop" 'my $stop = hard_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path, remove_startup => 1);' "stop success event" 'queue_agent_event("server_stop_confirmed", "info", {'

perl -0ne '
	$found = 1 if /write_desired_state_without_decrypt\(\$home_path, "running"\).*?sudo_exec_without_decrypt\(\$cli_bin, \$owner\);/s;
	END { exit($found ? 0 : 1) }
' "$agent" || fail "start must mark running desired state before launching the guarded watchdog"

obsolete_watchdog_sources="$(
	grep -nE '_startup_scr\.sh|_alsoRun\.cmd' "$agent" || true
)"
[ -z "$obsolete_watchdog_sources" ] || fail "obsolete watchdog active path remains: $obsolete_watchdog_sources"

active_hint_calls="$(
	grep -nE 'write_status_hint|read_status_hint' "$agent" |
		grep -vE 'sub write_status_hint|sub read_status_hint|get_status_hint_path|my \$hint_file = get_status_hint_path|unlink\(\$hint_file\)' || true
)"
[ -z "$active_hint_calls" ] || fail "legacy status hints must not be used by active lifecycle paths: $active_hint_calls"

echo "Linux watchdog stop contract validation passed."
