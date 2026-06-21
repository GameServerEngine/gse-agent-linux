#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="/home/gameserver/GSP"
DEFAULT_AGENT_USER="gameserver"
DEFAULT_SERVICE_NAME="gsp_agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")

usage() {
	cat <<EOF
GSP Linux Agent guided installer

Usage: sudo bash install.sh [options]

Options:
  --install-dir PATH       Install directory. Default: ${DEFAULT_INSTALL_DIR}
  --agent-user USER        Linux user that runs the agent. Default: ${DEFAULT_AGENT_USER}
  --service-name NAME      systemd service name. Default: ${DEFAULT_SERVICE_NAME}
  --no-service             Configure files but do not install a systemd service.
  --no-prereqs            Do not offer to run install_agent_prereqs.sh.
  --help                  Show this help.

Run install_agent_prereqs.sh first or allow this installer to run it.
EOF
}

ask() {
	local prompt="$1"
	local default_value="$2"
	local answer
	read -r -p "${prompt} [${default_value}]: " answer
	printf '%s' "${answer:-$default_value}"
}

ask_yes_no() {
	local prompt="$1"
	local default_value="$2"
	local answer
	while true; do
		read -r -p "${prompt} [${default_value}]: " answer
		answer="${answer:-$default_value}"
		case "$answer" in
			[yY]|[yY][eE][sS]) return 0 ;;
			[nN]|[nN][oO]) return 1 ;;
			*) echo "Enter yes or no." ;;
		esac
	done
}

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

require_root() {
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi
	if command -v sudo >/dev/null 2>&1; then
		echo "System service installation requires root. Re-running through sudo..."
		exec sudo -E bash "$0" "$@"
	fi
	fail "Run this installer as root: sudo bash install.sh"
}

validate_safe_path() {
	local path="$1"
	case "$path" in
		""|"/"|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*|/var|/var/*)
			fail "Refusing unsafe install directory: $path"
			;;
	esac
}

install_service() {
	local install_dir="$1"
	local agent_user="$2"
	local service_name="$3"
	local unit_path="/etc/systemd/system/${service_name}.service"

	command -v systemctl >/dev/null 2>&1 || {
		echo "systemd was not detected. Skipping service installation."
		return 0
	}

	cp "${install_dir}/systemd/gsp_agent.service" "$unit_path"
	sed -i \
		-e "s#{GSP_AGENT_PATH}#${install_dir}#g" \
		-e "s#{GSP_AGENT_USER}#${agent_user}#g" \
		-e "s#{GSP_AGENT_RUN_SCRIPT}#${install_dir}/gsp_agent_run#g" \
		-e "s#{GSP_AGENT_PID_FILE}#${install_dir}/gsp_agent_run.pid#g" \
		"$unit_path"

	systemctl daemon-reload
	systemctl enable "$service_name.service"
	if ask_yes_no "Start ${service_name}.service now?" "yes"; then
		systemctl restart "$service_name.service"
	fi
}

INSTALL_DIR=""
AGENT_USER=""
SERVICE_NAME=""
INSTALL_SERVICE=1
OFFER_PREREQS=1

while [ "$#" -gt 0 ]; do
	case "$1" in
		--install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
		--agent-user) AGENT_USER="${2:-}"; shift 2 ;;
		--service-name) SERVICE_NAME="${2:-}"; shift 2 ;;
		--no-service) INSTALL_SERVICE=0; shift ;;
		--no-prereqs) OFFER_PREREQS=0; shift ;;
		--help|-h) usage; exit 0 ;;
		*) fail "Unknown option: $1" ;;
	esac
done

require_root "${ORIG_ARGS[@]}"

echo "GSP Linux Agent installer"
echo
echo "This installer configures the Linux execution agent for GameServer Panel."
echo "Use the same key/password that is configured for this remote server in the Panel."
echo

if [ "$OFFER_PREREQS" -eq 1 ] && [ -x "${SCRIPT_DIR}/install_agent_prereqs.sh" ]; then
	if ask_yes_no "Run install_agent_prereqs.sh before installing?" "yes"; then
		bash "${SCRIPT_DIR}/install_agent_prereqs.sh"
	fi
elif [ "$OFFER_PREREQS" -eq 1 ]; then
	echo "Prerequisite installer is not executable. Run: chmod +x install_agent_prereqs.sh && sudo ./install_agent_prereqs.sh"
fi

INSTALL_DIR="${INSTALL_DIR:-$(ask "Install directory" "$DEFAULT_INSTALL_DIR")}"
AGENT_USER="${AGENT_USER:-$(ask "Agent Linux user" "$DEFAULT_AGENT_USER")}"
SERVICE_NAME="${SERVICE_NAME:-$(ask "systemd service name" "$DEFAULT_SERVICE_NAME")}"

validate_safe_path "$INSTALL_DIR"
INSTALL_DIR="${INSTALL_DIR%/}"

if ! id "$AGENT_USER" >/dev/null 2>&1; then
	if ask_yes_no "User ${AGENT_USER} does not exist. Create it?" "yes"; then
		useradd --create-home --shell /bin/bash "$AGENT_USER"
	else
		fail "Agent user is required."
	fi
fi

mkdir -p "$INSTALL_DIR"
if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
	rsync -a --exclude='.git/' --exclude='Cfg/Config.pm' --exclude='Cfg/Preferences.pm' --exclude='Cfg/bash_prefs.cfg' "${SCRIPT_DIR}/" "${INSTALL_DIR}/"
fi

mkdir -p \
	"${INSTALL_DIR}/Cfg" \
	"${INSTALL_DIR}/logs" \
	"${INSTALL_DIR}/tmp" \
	"${INSTALL_DIR}/screenlogs" \
	"${INSTALL_DIR}/runtime_status" \
	"${INSTALL_DIR}/events" \
	"${INSTALL_DIR}/_gsp_content/hooks" \
	"${INSTALL_DIR}/_gsp_content/generated" \
	"${INSTALL_DIR}/_gsp_content/runtime"

touch "${INSTALL_DIR}/_gsp_content/runtime/server_content.pids"

chmod +x "${INSTALL_DIR}/gsp_agent_run" "${INSTALL_DIR}/ogp_agent_run" "${INSTALL_DIR}/agent_conf.sh" "${INSTALL_DIR}/install_agent_prereqs.sh" 2>/dev/null || true
chown -R "${AGENT_USER}:${AGENT_USER}" "$INSTALL_DIR"

echo
echo "Configuring agent files..."
bash "${INSTALL_DIR}/agent_conf.sh" \
	--install-dir "$INSTALL_DIR" \
	--agent-user "$AGENT_USER" \
	--guided

if [ "$INSTALL_SERVICE" -eq 1 ]; then
	install_service "$INSTALL_DIR" "$AGENT_USER" "$SERVICE_NAME"
fi

cat <<EOF

GSP Linux Agent installation complete.

Config files:
  ${INSTALL_DIR}/Cfg/Config.pm
  ${INSTALL_DIR}/Cfg/Preferences.pm
  ${INSTALL_DIR}/Cfg/bash_prefs.cfg

Logs:
  ${INSTALL_DIR}/gsp_agent.log
  ${INSTALL_DIR}/screenlogs/

Useful commands:
  sudo systemctl status ${SERVICE_NAME}
  sudo journalctl -u ${SERVICE_NAME} -f
  tail -f ${INSTALL_DIR}/gsp_agent.log

Panel configuration still required:
  1. Add or edit the remote server in the GSP Panel.
  2. Use listen IP/port from Config.pm.
  3. Use the same agent key/shared secret from Config.pm.
  4. Open the configured agent port in the firewall.
EOF
