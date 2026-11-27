#!/usr/bin/env bash
# On-demand agent update helper (Linux).
#
# Started detached by the running agent right before the agent stops itself.
# The agent has already downloaded the release zip to a staging folder and
# that download's SHA-256 is passed in. This helper:
#   1. waits for the agent process to exit,
#   2. re-checks the SHA-256 of the staged zip,
#   3. keeps ONE backup of the current install (the install being replaced),
#   4. copies the new files in, leaving config and runtime data untouched,
#   5. starts the agent again, checks that the agent that is running started AFTER the new files were
#      in place (restarting it if not), and waits for it to stay up,
#   6. on any failure after the swap starts, restores the backup and restarts
#      the previous agent, then records the outcome.
#
# While the files are replaced the helper holds a file (agent_update_hold) that agent_core_run waits on
# before it starts the agent. Without it the supervisor restarts a stopped agent ten seconds later, in the
# middle of the copy, and the "new" agent is really the old code running from memory.
#
# Mirrors the Windows agent's agent_update_helper.sh so both agents take the
# same on-demand archive update from the panel; the only real difference is
# how the agent is started back up (systemd service here, Windows service
# there).
#
# Usage:
#   agent_update_helper.sh --agent-dir DIR --zip FILE --sha256 HEX \
#       --version VER --agent-pid PID --service-name NAME --state-file FILE --log-file FILE

set -u

AGENT_DIR=""; ZIP=""; EXPECTED_SHA=""; VERSION=""; AGENT_PID=""
SERVICE_NAME=""; STATE_FILE=""; LOG_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--agent-dir) AGENT_DIR="$2"; shift 2 ;;
		--zip) ZIP="$2"; shift 2 ;;
		--sha256) EXPECTED_SHA="$2"; shift 2 ;;
		--version) VERSION="$2"; shift 2 ;;
		--agent-pid) AGENT_PID="$2"; shift 2 ;;
		--service-name) SERVICE_NAME="$2"; shift 2 ;;
		--state-file) STATE_FILE="$2"; shift 2 ;;
		--log-file) LOG_FILE="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

for v in AGENT_DIR ZIP EXPECTED_SHA VERSION STATE_FILE LOG_FILE; do
	if [ -z "${!v}" ]; then echo "missing required argument for $v" >&2; exit 2; fi
done

BACKUP_DIR="$AGENT_DIR/agent_update_backup"
STAGE_DIR="$AGENT_DIR/agent_update_stage"
HOLD_FILE="$AGENT_DIR/agent_update_hold"
COPIED_AT=0
# Timings. The defaults are the real ones; the tests shorten them.
SETTLE_SECONDS="${GSE_UPDATE_SETTLE_SECONDS:-5}"
POLL_SECONDS="${GSE_UPDATE_POLL_SECONDS:-5}"
STABLE_SECONDS="${GSE_UPDATE_STABLE_SECONDS:-30}"

log() {
	mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

write_state() {
	# status, message, version_after, rollback_performed
	local status="$1" message="$2" version_after="$3" rolled_back="$4"
	local tmp="$STATE_FILE.tmp.$$"
	mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
	printf '{"status":"%s","message":"%s","version_target":"%s","version_after":"%s","rollback_performed":%s,"updated_at":"%s"}\n' \
		"$status" "${message//\"/\\\"}" "$VERSION" "$version_after" "$rolled_back" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp" \
		&& mv -f "$tmp" "$STATE_FILE"
}

# Preserved paths: never overwritten by an update and never part of the backup
# restore. Config, runtime data, and the update's own working folders.
is_preserved() {
	case "$1" in
		etc|etc/*|var|var/*|startups|startups/*) return 0 ;;
		agent_update_backup|agent_update_backup/*) return 0 ;;
		agent_update_stage|agent_update_stage/*) return 0 ;;
		Cfg/Config.pm|Cfg/Preferences.pm|Cfg/bash_prefs.cfg) return 0 ;;
		agent_core_update_state.json|agent_core_update_request.json|agent_core_update.log) return 0 ;;
	esac
	return 1
}

# The agent is a perl process. The PID the caller passes can be a different
# process from the one that holds the port, so find the real one by command line.
agent_pids() {
	local d pid
	for d in /proc/[0-9]*; do
		pid="${d#/proc/}"
		[ "$pid" = "$$" ] && continue
		if { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null | grep -q 'perl.*agent_core\.pl'; then
			echo "$pid"
		fi
	done
}

agent_running() {
	[ -n "$(agent_pids)" ]
}

# agent_core_run does not start the agent while this file exists. It is only a hold: the supervisor keeps
# running (under systemd it is the unit's main process, and ending it would end the unit and this helper).
hold_agent_restarts() {
	: > "$HOLD_FILE" 2>/dev/null || true
}

release_agent_restarts() {
	rm -f "$HOLD_FILE" 2>/dev/null || true
}
trap release_agent_restarts EXIT

# True when agent process $1 started before $2 (epoch seconds), the moment the new files were in place.
started_before() {
	local pid="$1" cutoff="$2" age start
	age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
	[ -n "$age" ] || return 1
	start=$(( $(date +%s) - age ))
	[ "$start" -lt "$cutoff" ]
}

# Agent processes that are still running code loaded before the update finished copying.
stale_agent_pids() {
	local pid
	for pid in $(agent_pids); do
		started_before "$pid" "$COPIED_AT" && echo "$pid"
	done
}

start_agent() {
	# Installs done by the current installer run the agent as a systemd
	# service; start it the same way agent_restart does. Fall back to the
	# legacy screen-based start for older or manually-run installs.
	if [ -n "$SERVICE_NAME" ] && [ -e "/etc/systemd/system/$SERVICE_NAME.service" ]; then
		systemctl start "$SERVICE_NAME" >/dev/null 2>&1
		return
	fi
	( cd "$AGENT_DIR" && screen -d -m -t "agent_core" -S agent_core bash agent_core_run -pidfile agent_core_run.pid ) >/dev/null 2>&1
}

wait_for_agent_up() {
	# Agent counts as up once it has stayed alive for 30 seconds (STABLE_SECONDS).
	local waited=0
	while [ "$waited" -lt 120 ]; do
		sleep "$POLL_SECONDS"; waited=$((waited + POLL_SECONDS))
		if [ -n "$(agent_pids)" ]; then
			local stable=0
			while [ "$stable" -lt "$STABLE_SECONDS" ]; do
				sleep "$POLL_SECONDS"; stable=$((stable + POLL_SECONDS))
				[ -n "$(agent_pids)" ] || break
			done
			[ -n "$(agent_pids)" ] && return 0
		fi
	done
	return 1
}

restore_backup() {
	log "Restoring previous install from $BACKUP_DIR"
	if [ ! -d "$BACKUP_DIR" ]; then
		log "No backup folder found; cannot restore"
		return 1
	fi
	( cd "$BACKUP_DIR" && find . -type f ) | while IFS= read -r rel; do
		rel="${rel#./}"
		is_preserved "$rel" && continue
		mkdir -p "$AGENT_DIR/$(dirname "$rel")"
		cp -f "$BACKUP_DIR/$rel" "$AGENT_DIR/$rel"
	done
	return 0
}

fail_and_restore() {
	local message="$1"
	log "FAILED: $message"
	release_agent_restarts
	if restore_backup; then
		start_agent
		if wait_for_agent_up; then
			write_state rolled_back "$message; previous agent restored and running" "$(cat "$AGENT_DIR/.agent_core_source_revision" 2>/dev/null || true)" true
		else
			write_state failed "$message; restore finished but agent did not start" "" true
		fi
	else
		write_state failed "$message; no backup available to restore" "" false
	fi
	rm -rf "$STAGE_DIR"
	exit 1
}

# Everything that runs the update is in one function, called on the last line. Bash reads a script as it goes,
# and this very file is replaced while it runs (it is one of the files being updated). Read as a function, the
# whole update is in memory before the first step runs, so a changed file cannot change what is executed.
main() {
	log "Helper started for version $VERSION"
	write_state running "Waiting for agent to stop" "" false

	# 1. Hold the supervisor, ask the agent to stop, then wait for it to exit.
	hold_agent_restarts
	log "Holding agent restarts while the files are replaced"
	sleep "$SETTLE_SECONDS"
	if agent_running; then
		log "Stopping agent: $(agent_pids | tr '\n' ' ')"
		for pid in $(agent_pids); do kill -TERM "$pid" 2>/dev/null || true; done
	fi
	waited=0
	while agent_running && [ "$waited" -lt 120 ]; do sleep 2; waited=$((waited + 2)); done
	if agent_running; then
		log "Agent did not stop after 120s; ending it"
		for pid in $(agent_pids); do kill -KILL "$pid" 2>/dev/null || true; done
		sleep 5
	fi
	if agent_running; then
		log "Agent still running; nothing was changed"
		write_state failed "Could not stop the running agent; nothing was changed" "" false
		rm -rf "$STAGE_DIR"
		exit 1
	fi
	rm -f "$AGENT_DIR/agent_core_run.pid" "$AGENT_DIR/agent_core.pid" 2>/dev/null || true
	log "Agent stopped"

	# 2. Re-check the staged zip.
	actual_sha="$(sha256sum "$ZIP" 2>/dev/null | cut -d' ' -f1 | tr 'A-F' 'a-f')"
	if [ "$actual_sha" != "$(printf '%s' "$EXPECTED_SHA" | tr 'A-F' 'a-f')" ]; then
		log "Checksum mismatch: expected $EXPECTED_SHA got ${actual_sha:-none}"
		write_state failed "Staged release checksum did not match; nothing was changed" "" false
		release_agent_restarts
		start_agent
		exit 1
	fi
	log "Checksum verified"

	# 3. Keep one backup of the current install (replaces any older backup).
	# Keep the staged zip: it lives inside the stage folder.
	rm -rf "$BACKUP_DIR" "$STAGE_DIR/payload"
	mkdir -p "$BACKUP_DIR" "$STAGE_DIR" || fail_and_restore "Cannot create backup or staging folder"
	( cd "$AGENT_DIR" && find . -type f ) | while IFS= read -r rel; do
		rel="${rel#./}"
		is_preserved "$rel" && continue
		mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
		cp -f "$AGENT_DIR/$rel" "$BACKUP_DIR/$rel" || exit 1
	done || fail_and_restore "Backup of current install failed"
	log "Backup of current install written to $BACKUP_DIR"

	# 4. Extract and copy the new files in.
	unzip -q -o "$ZIP" -d "$STAGE_DIR/payload" || fail_and_restore "Could not extract release zip"
	payload="$STAGE_DIR/payload"
	# GitHub tag archives wrap the whole repo in one <repo>-<tag>/ folder; step into it.
	top="$(find "$payload" -mindepth 1 -maxdepth 1 | head -n 2)"
	if [ "$(printf "%s\n" "$top" | grep -c .)" = 1 ] && [ -d "$top" ]; then payload="$top"; fi
	[ -f "$payload/agent_core.pl" ] || fail_and_restore "Release zip does not contain agent_core.pl"

	( cd "$payload" && find . -type f ) | while IFS= read -r rel; do
		rel="${rel#./}"
		is_preserved "$rel" && continue
		mkdir -p "$AGENT_DIR/$(dirname "$rel")"
		cp -f "$payload/$rel" "$AGENT_DIR/$rel" || exit 1
	done || fail_and_restore "Copying new files failed"
	printf '%s\n' "$VERSION" > "$AGENT_DIR/release_version.txt.tmp" && mv -f "$AGENT_DIR/release_version.txt.tmp" "$AGENT_DIR/release_version.txt"
	COPIED_AT="$(date +%s)"
	log "New files copied in"
	release_agent_restarts
	write_state running "New files installed; starting agent" "$VERSION" false

	# 5. Start the new agent, make sure the one that is running loaded the new files, and wait for it to stay up.
	start_agent
	wait_for_agent_up || fail_and_restore "New agent did not stay running after update"

	# A supervisor that predates the hold may have started the agent while the files were still being copied.
	# That agent is running the old code from memory, so it has to be restarted onto the new files.
	rounds=0
	while [ -n "$(stale_agent_pids)" ]; do
		rounds=$((rounds + 1))
		if [ "$rounds" -gt 2 ]; then
			log "The running agent still started before the new files were in place; leaving it running"
			write_state failed "New files installed, but the running agent started before they were copied in and could not be restarted. Restart the agent." "$VERSION" false
			rm -rf "$STAGE_DIR"
			exit 1
		fi
		log "Agent started before the new files were in place (pid $(stale_agent_pids | tr '\n' ' ')); restarting it"
		for pid in $(stale_agent_pids); do kill -TERM "$pid" 2>/dev/null || true; done
		waited=0
		while [ -n "$(stale_agent_pids)" ] && [ "$waited" -lt 60 ]; do sleep 2; waited=$((waited + 2)); done
		start_agent
		wait_for_agent_up || fail_and_restore "Agent did not come back after being restarted onto the new files"
	done

	log "New agent is running"
	write_state ok "Agent updated to $VERSION and running" "$VERSION" false
	rm -rf "$STAGE_DIR"
	exit 0
}

main "$@"; exit $?
