#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="/home/gameserver/GSP"
DEFAULT_AGENT_USER="gameserver"
DEFAULT_SERVICE_NAME="gsp_agent"
DEFAULT_REPO_URL="https://git.runlevelsystems.com/GSE/Agent-Linux"
DEFAULT_REPO_BRANCH="unstable"
DEFAULT_SOURCE_PATH="."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")

usage() {
	cat <<EOF
GSE Linux Agent installer

Usage: sudo bash install.sh [options]

Modes:
  install       Clone, configure, install service, and optionally start it. Default.
  repair        Re-copy agent code from repo/branch, preserve runtime config/data.
  reconfigure   Regenerate Cfg/Config.pm, Cfg/Preferences.pm, and Cfg/bash_prefs.cfg.

Options:
  --mode MODE              install, repair, or reconfigure.
  --repair                 Alias for --mode repair.
  --reconfigure            Alias for --mode reconfigure.
  --install-dir PATH       Install directory. Default: ${DEFAULT_INSTALL_DIR}
  --agent-user USER        Linux user that runs the agent. Default: ${DEFAULT_AGENT_USER}
  --service-name NAME      systemd service name. Default: ${DEFAULT_SERVICE_NAME}
  --repo-url URL           Git repository to install/update from. Default: ${DEFAULT_REPO_URL}
  --repo-branch BRANCH     Git branch to install/update from. Default: ${DEFAULT_REPO_BRANCH}
  --source-path PATH       Agent source path inside repo. Default: ${DEFAULT_SOURCE_PATH}
  --no-service             Configure files but do not install a systemd service.
  --no-prereqs             Do not offer to run install_agent_prereqs.sh.
  --non-interactive        Fail instead of prompting for missing decisions.
  --dry-run                Validate inputs and print planned actions without changing files.
  --help                   Show this help.

Run install_agent_prereqs.sh first or allow this installer to run it.
EOF
}

log() {
	printf '%s\n' "$*"
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

ask() {
	local prompt="$1"
	local default_value="$2"
	local answer
	if [ "$NON_INTERACTIVE" -eq 1 ]; then
		printf '%s' "$default_value"
		return 0
	fi
	read -r -p "${prompt} [${default_value}]: " answer
	printf '%s' "${answer:-$default_value}"
}

ask_yes_no() {
	local prompt="$1"
	local default_value="$2"
	local answer
	if [ "$NON_INTERACTIVE" -eq 1 ]; then
		case "$default_value" in
			[yY]|[yY][eE][sS]) return 0 ;;
			*) return 1 ;;
		esac
	fi
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

require_root() {
	if [ "$DRY_RUN" -eq 1 ]; then
		return 0
	fi
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi
	if command -v sudo >/dev/null 2>&1; then
		log "System installation requires root. Re-running through sudo..."
		exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
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

validate_repo_settings() {
	[[ "$REPO_URL" =~ ^(https?://|ssh://|git@|/) ]] || fail "Invalid repo URL: $REPO_URL"
	[[ "$REPO_URL" != *$'\n'* && "$REPO_URL" != *$'\r'* ]] || fail "Invalid repo URL."
	[[ "$REPO_BRANCH" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || fail "Invalid repo branch: $REPO_BRANCH"
	[[ "$SOURCE_PATH" =~ ^[A-Za-z0-9._/-]+$ && "$SOURCE_PATH" != *".."* ]] || fail "Invalid source path: $SOURCE_PATH"
}

install_service() {
	local install_dir="$1"
	local agent_user="$2"
	local service_name="$3"
	local unit_path="/etc/systemd/system/${service_name}.service"

	command -v systemctl >/dev/null 2>&1 || {
		log "systemd was not detected. Skipping service installation."
		return 0
	}

	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY-RUN: would install ${unit_path} and enable ${service_name}.service"
		return 0
	fi

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

clone_repo_with_retry() {
	local dest="$1"
	local attempt=1
	while true; do
		rm -rf "$dest"
		log "Cloning ${REPO_URL} branch ${REPO_BRANCH}..."
		if git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$dest"; then
			return 0
		fi
		if ! ask_yes_no "Clone failed on attempt ${attempt}. Retry?" "yes"; then
			fail "Cannot continue without a successful clone."
		fi
		attempt=$((attempt + 1))
	done
}

source_revision() {
	local repo_dir="$1"
	git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true
}

copy_agent_tree() {
	local source_dir="$1"
	local install_dir="$2"
	[ -d "$source_dir" ] || fail "Source path does not exist in clone: $source_dir"
	[ -s "$source_dir/gsp_agent.pl" ] || fail "Source path is missing gsp_agent.pl: $source_dir"
	[ -s "$source_dir/gsp_agent_run" ] || fail "Source path is missing gsp_agent_run: $source_dir"

	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY-RUN: would copy agent code from ${source_dir} to ${install_dir}"
		return 0
	fi

	mkdir -p "$install_dir"
	rsync -a \
		--exclude='.git/' \
		--exclude='Cfg/Config.pm' \
		--exclude='Cfg/Preferences.pm' \
		--exclude='Cfg/bash_prefs.cfg' \
		--exclude='ServerFiles/' \
		--exclude='logs/' \
		--exclude='screenlogs/' \
		--exclude='steamcmd/' \
		--exclude='startups/' \
		--exclude='runtime_status/' \
		--exclude='events/' \
		--exclude='tmp/' \
		--exclude='shared/' \
		--exclude='component_backups/' \
		--exclude='agent_self_update_backups/' \
		--exclude='agent_restart_update_backup.tar.gz' \
		--exclude='*.pid' \
		"${source_dir%/}/" "${install_dir}/"
}

ensure_runtime_dirs() {
	local install_dir="$1"
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY-RUN: would ensure runtime directories under ${install_dir}"
		return 0
	fi
	mkdir -p \
		"${install_dir}/Cfg" \
		"${install_dir}/logs" \
		"${install_dir}/tmp" \
		"${install_dir}/screenlogs" \
		"${install_dir}/runtime_status" \
		"${install_dir}/events" \
		"${install_dir}/_gsp_content/hooks" \
		"${install_dir}/_gsp_content/generated" \
		"${install_dir}/_gsp_content/runtime"
	touch "${install_dir}/_gsp_content/runtime/server_content.pids"
}

configure_agent() {
	local install_dir="$1"
	local agent_user="$2"
	if [ "$DRY_RUN" -eq 1 ]; then
		log "DRY-RUN: would run agent_conf.sh --guided for ${install_dir}"
		return 0
	fi
	bash "${install_dir}/agent_conf.sh" \
		--install-dir "$install_dir" \
		--agent-user "$agent_user" \
		--repo-url "$REPO_URL" \
		--repo-branch "$REPO_BRANCH" \
		--source-path "$SOURCE_PATH" \
		--guided
}

MODE="install"
INSTALL_DIR=""
AGENT_USER=""
SERVICE_NAME=""
REPO_URL=""
REPO_BRANCH=""
SOURCE_PATH=""
INSTALL_SERVICE=1
OFFER_PREREQS=1
NON_INTERACTIVE=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--mode) MODE="${2:-}"; shift 2 ;;
		--repair) MODE="repair"; shift ;;
		--reconfigure) MODE="reconfigure"; shift ;;
		--install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
		--agent-user) AGENT_USER="${2:-}"; shift 2 ;;
		--service-name) SERVICE_NAME="${2:-}"; shift 2 ;;
		--repo-url) REPO_URL="${2:-}"; shift 2 ;;
		--repo-branch) REPO_BRANCH="${2:-}"; shift 2 ;;
		--source-path) SOURCE_PATH="${2:-}"; shift 2 ;;
		--no-service) INSTALL_SERVICE=0; shift ;;
		--no-prereqs) OFFER_PREREQS=0; shift ;;
		--non-interactive) NON_INTERACTIVE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		--help|-h) usage; exit 0 ;;
		*) fail "Unknown option: $1" ;;
	esac
done

case "$MODE" in
	install|repair|reconfigure) ;;
	*) fail "Unknown mode: $MODE" ;;
esac

require_root

log "GSE Linux Agent ${MODE}"
log
log "This installer configures the Linux execution agent for Gameserver Engine."
log "Use the same key/password configured for this remote server in the Panel."
log

if [ "$OFFER_PREREQS" -eq 1 ] && [ "$MODE" != "reconfigure" ] && [ -x "${SCRIPT_DIR}/install_agent_prereqs.sh" ]; then
	if ask_yes_no "Run install_agent_prereqs.sh before installing?" "yes"; then
		if [ "$DRY_RUN" -eq 1 ]; then
			log "DRY-RUN: would run ${SCRIPT_DIR}/install_agent_prereqs.sh"
		else
			bash "${SCRIPT_DIR}/install_agent_prereqs.sh"
		fi
	fi
elif [ "$OFFER_PREREQS" -eq 1 ] && [ "$MODE" != "reconfigure" ]; then
	log "Prerequisite installer is not executable. Run: chmod +x install_agent_prereqs.sh && sudo ./install_agent_prereqs.sh"
fi

INSTALL_DIR="${INSTALL_DIR:-$(ask "Install directory" "$DEFAULT_INSTALL_DIR")}"
AGENT_USER="${AGENT_USER:-$(ask "Agent Linux user" "$DEFAULT_AGENT_USER")}"
SERVICE_NAME="${SERVICE_NAME:-$(ask "systemd service name" "$DEFAULT_SERVICE_NAME")}"
REPO_URL="${REPO_URL:-$(ask "GSE Linux agent Git repository URL" "$DEFAULT_REPO_URL")}"
REPO_BRANCH="${REPO_BRANCH:-$(ask "GSE Linux agent Git branch" "$DEFAULT_REPO_BRANCH")}"
SOURCE_PATH="${SOURCE_PATH:-$(ask "Agent source path inside repository" "$DEFAULT_SOURCE_PATH")}"

INSTALL_DIR="${INSTALL_DIR%/}"
validate_safe_path "$INSTALL_DIR"
validate_repo_settings

if [ "$DRY_RUN" -eq 1 ]; then
	log "DRY-RUN: mode=${MODE}"
	log "DRY-RUN: install_dir=${INSTALL_DIR}"
	log "DRY-RUN: agent_user=${AGENT_USER}"
	log "DRY-RUN: service_name=${SERVICE_NAME}"
	log "DRY-RUN: repo=${REPO_URL} branch=${REPO_BRANCH} source_path=${SOURCE_PATH}"
	exit 0
fi

if ! id "$AGENT_USER" >/dev/null 2>&1; then
	if ask_yes_no "User ${AGENT_USER} does not exist. Create it?" "yes"; then
		useradd --create-home --shell /bin/bash "$AGENT_USER"
	else
		fail "Agent user is required."
	fi
fi

TMP_DIR=""
cleanup() {
	[ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ "$MODE" != "reconfigure" ]; then
	command -v git >/dev/null 2>&1 || fail "git is required. Run install_agent_prereqs.sh first."
	command -v rsync >/dev/null 2>&1 || fail "rsync is required. Run install_agent_prereqs.sh first."
	TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gsp-agent-install.XXXXXX")"
	clone_repo_with_retry "$TMP_DIR/repo"
	SRC_DIR="${TMP_DIR}/repo/${SOURCE_PATH#./}"
	copy_agent_tree "$SRC_DIR" "$INSTALL_DIR"
	REVISION="$(source_revision "$TMP_DIR/repo")"
	printf '%s\n' "$REVISION" > "${INSTALL_DIR}/.gsp_agent_source_revision"
fi

ensure_runtime_dirs "$INSTALL_DIR"
chmod +x "${INSTALL_DIR}/gsp_agent_run" "${INSTALL_DIR}/agent_conf.sh" "${INSTALL_DIR}/install_agent_prereqs.sh" 2>/dev/null || true
chown -R "${AGENT_USER}:${AGENT_USER}" "$INSTALL_DIR"

if [ "$MODE" = "install" ] || [ ! -f "${INSTALL_DIR}/Cfg/Config.pm" ] || [ ! -f "${INSTALL_DIR}/Cfg/Preferences.pm" ] || [ ! -f "${INSTALL_DIR}/Cfg/bash_prefs.cfg" ]; then
	log
	log "Configuring agent files..."
	configure_agent "$INSTALL_DIR" "$AGENT_USER"
elif [ "$MODE" = "repair" ] && ask_yes_no "Runtime config already exists. Reconfigure it now?" "no"; then
	configure_agent "$INSTALL_DIR" "$AGENT_USER"
elif [ "$MODE" = "reconfigure" ]; then
	configure_agent "$INSTALL_DIR" "$AGENT_USER"
fi

chown -R "${AGENT_USER}:${AGENT_USER}" "$INSTALL_DIR"

if [ "$INSTALL_SERVICE" -eq 1 ]; then
	install_service "$INSTALL_DIR" "$AGENT_USER" "$SERVICE_NAME"
fi

cat <<EOF

GSE Linux Agent ${MODE} complete.

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
  cd ${INSTALL_DIR} && ./gsp_agent_run --log-stdout

Panel configuration still required:
  1. Add or edit the remote server in the GSE Panel.
  2. Use listen IP/port from Config.pm.
  3. Use the same agent key/shared secret from Config.pm.
  4. Open the configured agent port in the firewall.
EOF
