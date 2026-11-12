#!/usr/bin/env bash

set -euo pipefail

DEFAULT_PORT="12679"
DEFAULT_IP="0.0.0.0"
DEFAULT_AGENT_VERSION="v1.4"
DEFAULT_FTP_METHOD="PureFTPd"
DEFAULT_FTP_PORT="21"
DEFAULT_FTP_PASV_RANGE=""
DEFAULT_REPO_URL="https://git.runlevelsystems.com/GSE/Agent-Linux"
DEFAULT_REPO_BRANCH="unstable"
DEFAULT_SOURCE_PATH="."

usage() {
	cat <<EOF
GSE Linux Agent configuration helper

Usage:
  ./agent_conf.sh --guided
  ./agent_conf.sh [options]

Options:
  --install-dir PATH          Agent install directory. Default: directory containing this script.
  --agent-user USER           Owner for generated config files.
  --key VALUE                 Agent key/shared secret from the GSE Panel remote-server record.
  --listen-ip IP              Agent bind IP. Default: ${DEFAULT_IP}
  --listen-port PORT          Agent bind port. Default: ${DEFAULT_PORT}
  --sudo-password VALUE       Optional sudo password for legacy sudo_exec flows.
  --web-api-url URL           Panel api.php URL.
  --agent-event-url URL       Panel agent_event_receiver.php URL.
  --remote-server-id ID       Panel remote host ID.
  --ftp-managed 0|1           Whether GSE should manage FTP accounts. Default: 1
  --ftp-method NAME           FTP backend. Default: ${DEFAULT_FTP_METHOD}
  --auto-restart 0|1          Restart crashed game servers. Default: 1
  --auto-update 0|1           Restart-time agent auto update. Default: 0
  --repo-url URL              Git repository used by restart-time update.
  --repo-branch BRANCH        Git branch used by restart-time update.
  --source-path PATH          Agent source path inside the update repository.
  --guided                    Prompt for missing values.
  --help                      Show this help.

Legacy aliases:
  -s VALUE maps to --sudo-password
  -u USER  maps to --agent-user

This script writes:
  Cfg/Config.pm
  Cfg/Preferences.pm
  Cfg/bash_prefs.cfg
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_dir="$script_dir"
agent_user=""
guided=0
key=""
listen_ip="$DEFAULT_IP"
listen_port="$DEFAULT_PORT"
sudo_password=""
web_api_url=""
agent_event_url=""
remote_server_id=""
steam_license="Accept"
ftp_managed="1"
ftp_method="$DEFAULT_FTP_METHOD"
auto_restart="1"
auto_update="0"
screen_log_local="1"
delete_logs_after="30"
linux_user_per_game_server="1"
protocol_shutdown_waittime="10"
ftp_port="$DEFAULT_FTP_PORT"
ftp_ip="$DEFAULT_IP"
ftp_pasv_range="$DEFAULT_FTP_PASV_RANGE"
repo_url="$DEFAULT_REPO_URL"
repo_branch="$DEFAULT_REPO_BRANCH"
source_path="$DEFAULT_SOURCE_PATH"

ask() {
	local prompt="$1"
	local default_value="$2"
	local answer
	read -r -p "${prompt} [${default_value}]: " answer
	printf '%s' "${answer:-$default_value}"
}

ask_secret() {
	local prompt="$1"
	local answer
	read -r -s -p "${prompt}: " answer
	echo
	printf '%s' "$answer"
}

require_01() {
	local name="$1"
	local value="$2"
	[[ "$value" =~ ^[01]$ ]] || {
		echo "ERROR: ${name} must be 0 or 1." >&2
		exit 1
	}
}

perl_quote() {
	local value="${1-}"
	value="${value//\\/\\\\}"
	value="${value//\'/\\\'}"
	printf '%s' "$value"
}

shell_assignment() {
	local name="$1"
	local value="$2"
	printf '%s=%q\n' "$name" "$value"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--install-dir) install_dir="${2:-}"; shift 2 ;;
		--agent-user) agent_user="${2:-}"; shift 2 ;;
		--key) key="${2:-}"; shift 2 ;;
		--listen-ip) listen_ip="${2:-}"; shift 2 ;;
		--listen-port) listen_port="${2:-}"; shift 2 ;;
		--sudo-password) sudo_password="${2:-}"; shift 2 ;;
		--web-api-url) web_api_url="${2:-}"; shift 2 ;;
		--agent-event-url) agent_event_url="${2:-}"; shift 2 ;;
		--remote-server-id) remote_server_id="${2:-}"; shift 2 ;;
		--ftp-managed) ftp_managed="${2:-}"; shift 2 ;;
		--ftp-method) ftp_method="${2:-}"; shift 2 ;;
		--auto-restart) auto_restart="${2:-}"; shift 2 ;;
		--auto-update) auto_update="${2:-}"; shift 2 ;;
		--repo-url) repo_url="${2:-}"; shift 2 ;;
		--repo-branch) repo_branch="${2:-}"; shift 2 ;;
		--source-path) source_path="${2:-}"; shift 2 ;;
		--guided) guided=1; shift ;;
		-s) sudo_password="${2:-}"; shift 2 ;;
		-u) agent_user="${2:-}"; shift 2 ;;
		--help|-h) usage; exit 0 ;;
		*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

install_dir="${install_dir%/}"
cfg_dir="${install_dir}/Cfg"
cfgfile="${cfg_dir}/Config.pm"
prefsfile="${cfg_dir}/Preferences.pm"
bashprefsfile="${cfg_dir}/bash_prefs.cfg"

if [ "$guided" -eq 1 ]; then
	echo "GSE Linux Agent configuration"
	echo "Use values from Panel -> Administration -> Game Servers for this remote server."
	echo
	key="${key:-$(ask_secret "Agent key/shared secret")}"
	listen_ip="$(ask "Listen IP" "$listen_ip")"
	listen_port="$(ask "Listen port" "$listen_port")"
	web_api_url="$(ask "Panel API URL, usually https://panel.example.com/api.php" "$web_api_url")"
	agent_event_url="$(ask "Panel event receiver URL, usually https://panel.example.com/agent_event_receiver.php" "$agent_event_url")"
	remote_server_id="$(ask "Panel remote host ID" "$remote_server_id")"
	ftp_managed="$(ask "Manage FTP accounts? 1=yes, 0=no" "$ftp_managed")"
	ftp_method="$(ask "FTP method" "$ftp_method")"
	auto_restart="$(ask "Restart crashed game servers? 1=yes, 0=no" "$auto_restart")"
	auto_update="$(ask "Restart-time agent auto-update? 1=yes, 0=no" "$auto_update")"
	repo_url="$(ask "Restart-time update repository URL" "$repo_url")"
	repo_branch="$(ask "Restart-time update branch" "$repo_branch")"
	source_path="$(ask "Agent source path inside update repository" "$source_path")"
	if [ -z "$sudo_password" ]; then
		sudo_password="$(ask_secret "Optional sudo password for legacy sudo_exec flows, leave blank if not used")"
	fi
fi

[ -n "$key" ] || key="CHANGE_ME_PANEL_AGENT_KEY"
if [ "${#key}" -gt 16 ]; then
	echo "ERROR: the agent key can be at most 16 characters (the Panel and the agent cannot use a longer key)." >&2
	exit 1
fi
[[ "$listen_port" =~ ^[0-9]+$ ]] || {
	echo "ERROR: listen port must be numeric." >&2
	exit 1
}
require_01 "ftp-managed" "$ftp_managed"
require_01 "auto-restart" "$auto_restart"
require_01 "auto-update" "$auto_update"
[[ "$repo_url" =~ ^(https?://|ssh://|git@|/) && "$repo_url" != *$'\n'* && "$repo_url" != *$'\r'* ]] || {
	echo "ERROR: invalid update repository URL." >&2
	exit 1
}
[[ "$repo_branch" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || {
	echo "ERROR: invalid update branch." >&2
	exit 1
}
[[ "$source_path" =~ ^[A-Za-z0-9._/-]+$ && "$source_path" != *".."* ]] || {
	echo "ERROR: invalid update source path." >&2
	exit 1
}

mkdir -p "$cfg_dir" "${install_dir}/logs" "${install_dir}/tmp" "${install_dir}/screenlogs" "${install_dir}/runtime_status" "${install_dir}/events" "${install_dir}/_game_content/hooks" "${install_dir}/_game_content/generated" "${install_dir}/_game_content/runtime"

key_q="$(perl_quote "$key")"
listen_ip_q="$(perl_quote "$listen_ip")"
listen_port_q="$(perl_quote "$listen_port")"
sudo_password_q="$(perl_quote "$sudo_password")"
web_api_url_q="$(perl_quote "$web_api_url")"
agent_event_url_q="$(perl_quote "$agent_event_url")"
remote_server_id_q="$(perl_quote "$remote_server_id")"
install_dir_q="$(perl_quote "$install_dir")"
ftp_method_q="$(perl_quote "$ftp_method")"

cat > "$cfgfile" <<EOF
%Cfg::Config = (
	logfile => '${install_dir_q}/agent_core.log',
	listen_port => '${listen_port_q}',
	listen_ip => '${listen_ip_q}',
	version => '${DEFAULT_AGENT_VERSION}',
	key => '${key_q}',
	steam_license => '${steam_license}',
	sudo_password => '${sudo_password_q}',
	web_admin_api_key => '',
	web_api_url => '${web_api_url_q}',
	agent_event_url => '${agent_event_url_q}',
	remote_server_id => '${remote_server_id_q}',
	steam_dl_limit => '0',
	stats_db_host => '',
	stats_db_user => '',
	stats_db_pass => '',
	stats_db_name => '',
	stats_table_prefix => '',
	stats_frequency_minutes => '5',
);
EOF

cat > "$prefsfile" <<EOF
%Cfg::Preferences = (
	screen_log_local => '${screen_log_local}',
	delete_logs_after => '${delete_logs_after}',
	manages_ftp => '${ftp_managed}',
	ftp_method => '${ftp_method_q}',
	autorestart_server => '${auto_restart}',
	protocol_shutdown_waittime => '${protocol_shutdown_waittime}',
	linux_user_per_game_server => '${linux_user_per_game_server}',
	PortValidationEnabled => '1',
	StartupValidationTimeoutSeconds => '180',
	PortCheckIntervalSeconds => '5',
);
EOF

{
	shell_assignment agent_auto_update "$auto_update"
	shell_assignment agent_update_repo_url "$repo_url"
	shell_assignment agent_update_branch "$repo_branch"
	shell_assignment agent_update_source_path "$source_path"
	shell_assignment run_pureftpd "$ftp_managed"
	shell_assignment ftp_port "$ftp_port"
	shell_assignment ftp_ip "$ftp_ip"
	shell_assignment ftp_pasv_range "$ftp_pasv_range"
} > "$bashprefsfile"

chmod 600 "$cfgfile"
chmod 644 "$prefsfile" "$bashprefsfile"

if [ -n "$agent_user" ] && [ "$(id -u)" -eq 0 ] && id "$agent_user" >/dev/null 2>&1; then
	chown "$agent_user:$agent_user" "$cfgfile" "$prefsfile" "$bashprefsfile"
fi

echo "Wrote ${cfgfile}"
echo "Wrote ${prefsfile}"
echo "Wrote ${bashprefsfile}"
echo
echo "Next: ensure the Panel remote-server record uses listen_ip=${listen_ip}, listen_port=${listen_port}, and the same key."
