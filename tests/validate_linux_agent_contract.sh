#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

require_file() {
	[ -f "$1" ] || fail "missing file: ${1#$repo_root/}"
}

require_text() {
	local file="$1"
	local pattern="$2"
	grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in ${file#$repo_root/}"
}

require_absent_active() {
	local pattern="$1"
	if matches="$(git -C "$repo_root" grep -nF -- "$pattern" -- . \
		':(exclude)docs/codex-history/**' \
		':(exclude)docs/agent-modernization-step-1-divergence-report.md' 2>/dev/null)"; then
		printf '%s\n' "$matches" >&2
		fail "stale active reference remains: $pattern"
	fi
}

require_absent_regex_active() {
	local pattern="$1"
	if matches="$(git -C "$repo_root" grep -nE -- "$pattern" -- . \
		':(exclude)docs/codex-history/**' \
		':(exclude)docs/agent-modernization-step-1-divergence-report.md' 2>/dev/null)"; then
		printf '%s\n' "$matches" >&2
		fail "unexpected active match remains: $pattern"
	fi
}

require_file "$repo_root/gsp_agent.pl"
require_file "$repo_root/install.sh"
require_file "$repo_root/install_agent_prereqs.sh"
require_file "$repo_root/agent_conf.sh"
require_file "$repo_root/gsp_agent_run"
require_file "$repo_root/systemd/gsp_agent.service"
require_file "$repo_root/Cfg/bash_prefs.cfg.default"
require_file "$repo_root/tests/validate_steamcmd_bootstrap_payload.sh"
require_file "$repo_root/steamcmd/steamcmd.sh"
require_file "$repo_root/steamcmd/linux32/steamcmd"
require_file "$repo_root/steamcmd/linux32/steamerrorreporter"
require_file "$repo_root/steamcmd/linux32/libstdc++.so.6"
require_file "$repo_root/steamcmd/linux32/crashhandler.so"

[ -x "$repo_root/steamcmd/steamcmd.sh" ] || fail "steamcmd/steamcmd.sh must be executable"
[ -x "$repo_root/steamcmd/linux32/steamcmd" ] || fail "steamcmd/linux32/steamcmd must be executable"

perl -c "$repo_root/gsp_agent.pl" >/dev/null
bash -n "$repo_root/install.sh" "$repo_root/install_agent_prereqs.sh" "$repo_root/agent_conf.sh" "$repo_root/gsp_agent_run"
bash -n "$repo_root/tests/validate_steamcmd_bootstrap_payload.sh"
"$repo_root/tests/validate_steamcmd_bootstrap_payload.sh" >/dev/null

for file in "$repo_root/install.sh" "$repo_root/agent_conf.sh" "$repo_root/Cfg/bash_prefs.cfg.default"; do
	require_text "$file" "https://git.runlevelsystems.com/GSE/Agent-Linux"
	require_text "$file" "unstable"
done

for mode in install repair reconfigure uninstall; do
	require_text "$repo_root/install.sh" "$mode"
	"$repo_root/install.sh" --mode "$mode" --dry-run --non-interactive --no-prereqs --no-service >/dev/null
done

require_text "$repo_root/install.sh" "validate_staged_payload"
require_text "$repo_root/install.sh" "validate_installed_payload"
require_text "$repo_root/install.sh" "validate_steamcmd_bootstrap"
require_text "$repo_root/install.sh" "restore_missing_steamcmd_bootstrap"
require_text "$repo_root/install.sh" "uninstall_agent"
require_text "$repo_root/install.sh" "--purge-data"
require_text "$repo_root/install.sh" "remove_managed_agent_files"
require_text "$repo_root/install.sh" "systemctl stop"
require_text "$repo_root/install.sh" "systemctl disable"
require_text "$repo_root/install.sh" "rm -f \"\$unit_path\""

require_text "$repo_root/gsp_agent.pl" "PortValidationEnabled"
require_text "$repo_root/gsp_agent.pl" "StartupValidationTimeoutSeconds"
require_text "$repo_root/gsp_agent.pl" "PortCheckIntervalSeconds"
require_text "$repo_root/gsp_agent.pl" "CPUUsage => agent_cpu_usage_percent()"
require_text "$repo_root/gsp_agent.pl" "MemoryUsage => agent_ram_usage_percent()"
require_text "$repo_root/gsp_agent.pl" "sub build_expected_ports"
require_text "$repo_root/gsp_agent.pl" "sub validate_expected_ports"
require_text "$repo_root/gsp_agent.pl" "sub has_listening_port_named"
require_text "$repo_root/gsp_agent.pl" 'my $os = `uname -sr 2>/dev/null`;'
require_text "$repo_root/gsp_agent.pl" "clear_pid_metadata(\$home_id);"
require_text "$repo_root/gsp_agent.pl" "SteamCMD is unavailable. Expected bundled bootstrap executable"
require_text "$repo_root/gsp_agent.pl" "SteamCMD bootstrap missing from source payload"
require_text "$repo_root/gsp_agent_run" "restore_missing_steamcmd_bootstrap"

legacy_linux_repo="$(printf '%s%s' 'GSP-Agent' '-Linux')"
legacy_github_gsp="$(printf '%s%s%s%s' 'https://github.com/' 'OpenGamePanel/' 'GSP-Agent' '-Linux')"
legacy_github_ogp="$(printf '%s%s%s%s' 'https://github.com/' 'OpenGamePanel/' 'OGP-Agent' '-Linux')"
legacy_forge="$(printf '%s%s%s' 'forge.' 'runlevelsystems.com/dev/' 'GSP.git')"
legacy_branch="$(printf '%s%s' 'Panel' '-unstable')"
legacy_steamcmd_http="$(printf '%s%s' 'http://media.steampowered.com/client/' 'steamcmd_linux.tar.gz')"
legacy_steamcmd_download="$(printf '%s%s' '$ua->get($steam' '_client_url')"
windows_only_regex="$(printf '%s|%s|%s|%s|%s|%s' 'power''shell' 'cyg''path' 'cyg''runsrv' 'ic''acls' 'task''kill' 'cmd\\.exe')"

require_absent_active "$legacy_linux_repo"
require_absent_active "$legacy_github_gsp"
require_absent_active "$legacy_github_ogp"
require_absent_active "$legacy_forge"
require_absent_active "$legacy_branch"
require_absent_active "$legacy_steamcmd_http"
require_absent_active "$legacy_steamcmd_download"
require_absent_regex_active "$windows_only_regex"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gse-linux-agent-test.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
touch "$tmpdir/gsp_agent_run"
chmod +x "$tmpdir/gsp_agent_run"
sed \
	-e "s#{GSP_AGENT_PATH}#${tmpdir}#g" \
	-e "s#{GSP_AGENT_USER}#$(id -un)#g" \
	-e "s#{GSP_AGENT_RUN_SCRIPT}#${tmpdir}/gsp_agent_run#g" \
	-e "s#{GSP_AGENT_PID_FILE}#${tmpdir}/gsp_agent_run.pid#g" \
	"$repo_root/systemd/gsp_agent.service" > "$tmpdir/gsp_agent.service"

if command -v systemd-analyze >/dev/null 2>&1; then
	systemd-analyze verify "$tmpdir/gsp_agent.service" >/dev/null
else
	echo "SKIP: systemd-analyze is not available"
fi

echo "Linux agent installer and RPC contract validation passed."
