#!/usr/bin/env bash
# GSE Linux Agent installer for Ubuntu 22.04+ and Debian 12+.
#
# Before you run it: on the panel, open Administration > Servers and add this machine
# (IP, agent port, an agent key of up to 16 characters, and the agent user). The agent
# is not running yet, so the panel saves the server and waits for this installer.
#
# The installer asks for the panel address, that agent key and the agent user's
# password. It then gets the server's settings from the panel, downloads the agent
# release the panel's update settings pick, installs the prerequisites, creates the
# agent user, writes the agent configuration, installs and starts the systemd service
# and tells the panel the agent is ready.
#
# Usage:
#   sudo bash gse-agent-linux-install.sh [--panel URL] [--key KEY] [--path DIR] [--zip FILE]
#     --panel URL   panel address, as you open it in a browser (http://panel.example.com/panel)
#     --key KEY     the agent key you entered on the panel's Servers page
#     --path DIR    install folder (default /home/<agent user>/GSP)
#     --zip FILE    install this local release ZIP instead of downloading one
# GSE_AGENT_PASSWORD in the environment answers the password question.
set -euo pipefail

REPO="GameServerEngine/gse-agent-linux"
PANEL=""; KEY=""; AGENT_DIR=""; ZIP=""
PASSWORD="${GSE_AGENT_PASSWORD:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# ask "Question" [default] [secret]  -> prints the answer, read from the terminal
ask() {
	local answer="" flags="-r"
	[ "${3:-}" = secret ] && flags="-rs"
	[ -r /dev/tty ] || die "No terminal to ask \"$1\". Pass it as an option."
	read $flags -p "$1${2:+ [$2]}: " answer </dev/tty || true
	[ "${3:-}" = secret ] && echo >&2
	echo "${answer:-${2:-}}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--panel) PANEL="$2"; shift 2 ;;
		--key) KEY="$2"; shift 2 ;;
		--path) AGENT_DIR="${2%/}"; shift 2 ;;
		--zip) ZIP="$2"; shift 2 ;;
		-h|--help) sed -n '2,21p' "$0"; exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[ "$(id -u)" -eq 0 ] || die "Run this installer as root (sudo bash $0)."
. /etc/os-release
case "$ID:${VERSION_ID%%.*}" in
	ubuntu:2[2-9]|ubuntu:[3-9]?|debian:1[2-9]) ;;
	*) die "Unsupported system $PRETTY_NAME. Use Ubuntu 22.04+ or Debian 12+." ;;
esac

[ -n "$PANEL" ] || PANEL=$(ask "Panel address (as you open it in a browser)")
[ -n "$PANEL" ] || die "The panel address is required."
case "$PANEL" in http://*|https://*) ;; *) PANEL="http://$PANEL" ;; esac
PANEL="${PANEL%/}"; PANEL="${PANEL%/index.php}"; PANEL="${PANEL%/home.php}"
[ -n "$KEY" ] || KEY=$(ask "Agent key from the panel's Servers page" "" secret)
[ -n "$KEY" ] || die "The agent key is required."

say "Installing the tools this installer needs"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl unzip openssl jq ca-certificates iproute2

# Signed request to the panel's agent_enroll.php (see that file). Prints the JSON reply.
panel_call() {
	local body="{\"step\":\"$1\",\"os\":\"linux\"}" ts sig reply code
	ts=$(date +%s)
	sig=$(printf '%s' "$ts.$body" | openssl dgst -sha256 -hmac "$KEY" -r | awk '{print $1}')
	reply=$(curl -sS --max-time 60 -w '\n%{http_code}' -H 'Content-Type: application/json' \
		-H "X-GSE-Timestamp: $ts" -H "X-GSE-Signature: sha256=$sig" \
		--data "$body" "$PANEL/agent_enroll.php") || die "Could not reach the panel at $PANEL."
	code=$(echo "$reply" | tail -n1); reply=$(echo "$reply" | sed '$d')
	case "$code:$(echo "$reply" | jq -r '.error // empty' 2>/dev/null)" in
		200:*) echo "$reply" ;;
		401:unknown_key) die "The panel has no server with this agent key. Add this machine on the panel's Servers page first." ;;
		401:bad_timestamp) die "This machine's clock differs from the panel's by more than 5 minutes. Fix the time and run again." ;;
		404:*) die "$PANEL/agent_enroll.php was not found. Check the panel address, and that the panel is up to date." ;;
		*) die "The panel answered HTTP $code: $reply" ;;
	esac
}

say "Asking the panel for this server's settings"
CONFIG=$(panel_call config)
cfg() { echo "$CONFIG" | jq -r "$1 // empty"; }
SERVER_ID=$(cfg .remote_server_id); AGENT_USER=$(cfg .user); AGENT_IP=$(cfg .agent_ip)
AGENT_PORT=$(cfg .agent_port); FTP_IP=$(cfg .ftp_ip); FTP_PORT=$(cfg .ftp_port)
[ -n "$SERVER_ID" ] && [ -n "$AGENT_PORT" ] || die "The panel's answer is incomplete: $CONFIG"
[ -n "$AGENT_USER" ] || AGENT_USER=gameserver
[[ "$AGENT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ "$AGENT_USER" != root ] || die "The agent user \"$AGENT_USER\" set on the panel is not a valid Linux user name."
say "Panel server $SERVER_ID ($(cfg .name)): agent user $AGENT_USER, port $AGENT_PORT"

[ -n "$AGENT_DIR" ] || AGENT_DIR="/home/$AGENT_USER/GSP"
case "$AGENT_DIR" in /|/bin*|/boot*|/dev*|/etc*|/lib*|/proc*|/root*|/sbin*|/sys*|/usr*) die "The agent cannot be installed in $AGENT_DIR." ;; esac
[ ! -e "$AGENT_DIR/Cfg/Config.pm" ] || ! grep -q "remote_server_id => '[0-9]" "$AGENT_DIR/Cfg/Config.pm" \
	|| die "An agent is already installed in $AGENT_DIR. Update it from the panel."

# ---------- agent user (asked now, created after the prerequisites) ----------
if [ -z "$PASSWORD" ]; then
	PASSWORD=$(ask "Password for the agent user $AGENT_USER (created if missing)" "" secret)
	if ! id "$AGENT_USER" >/dev/null 2>&1; then
		[ "$PASSWORD" = "$(ask "Type the password again" "" secret)" ] || die "The passwords do not match."
	fi
fi
[ -n "$PASSWORD" ] || die "A password is required: the agent uses it with sudo."

# ---------- release ----------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Newest stable GitHub release that has a checksum, else the newest testing release.
github_release() {
	local api="https://api.github.com/repos/$REPO/releases" urls
	urls=$(curl -fsSL "$api/latest" 2>/dev/null | grep -o 'https://[^"]*/releases/download/[^"]*' || true)
	if echo "$urls" | grep -q '\.zip\.sha256$'; then echo "$urls" | grep '\.zip$' | head -n1; return; fi
	curl -fsSL "$api?per_page=30" | grep -o 'https://[^"]*/releases/download/testing-[^"]*\.zip' | head -n1 || true
}

if [ -n "$ZIP" ]; then
	[ -s "$ZIP" ] || die "ZIP file not found: $ZIP"
	cp "$ZIP" "$WORK/agent.zip"
	say "Using local ZIP $ZIP"
else
	URL=$(cfg .release.url); SUM_URL=$(cfg .release.sha256_url)
	if [ -z "$URL" ]; then
		say "The panel did not name a release; looking on GitHub"
		URL=$(github_release); SUM_URL="$URL.sha256"
	fi
	[ -n "$URL" ] || die "Could not find an agent release."
	say "Downloading $URL"
	curl -fL --retry 3 --connect-timeout 20 -o "$WORK/agent.zip" "$URL"
	SUM=$(curl -fsSL --retry 3 "$SUM_URL" | awk '{print $1}')
	[ -n "$SUM" ] || die "The release has no checksum file."
	echo "$SUM  $WORK/agent.zip" | sha256sum -c --quiet - || die "Checksum mismatch. Nothing was installed."
	say "Checksum OK"
fi
unzip -q "$WORK/agent.zip" -d "$WORK/x"
SRC="$WORK/x"
if [ "$(ls -A "$SRC" | wc -l)" = 1 ] && [ -d "$SRC/$(ls -A "$SRC")" ]; then SRC="$SRC/$(ls -A "$SRC")"; fi
[ -f "$SRC/agent_core.pl" ] && [ -f "$SRC/agent_core_run" ] || die "The ZIP does not contain the Linux agent."

say "Installing the agent prerequisites (Perl modules, screen, Pure-FTPd, 32-bit libraries)"
# "yes" answers its question about 32-bit packages.
echo yes | bash "$SRC/install_agent_prereqs.sh"

if id "$AGENT_USER" >/dev/null 2>&1; then
	say "Using the existing user $AGENT_USER"
else
	say "Creating the user $AGENT_USER"
	useradd -m -s /bin/bash "$AGENT_USER"
	echo "$AGENT_USER:$PASSWORD" | chpasswd
fi
usermod -aG sudo "$AGENT_USER"
# The agent runs privileged steps as: echo <password> | sudo -S ...
su -s /bin/bash "$AGENT_USER" -c 'sudo -S -k -p "" true' <<<"$PASSWORD" >/dev/null 2>&1 \
	|| die "sudo does not accept this password for $AGENT_USER. Check the password and run again."

say "Copying the agent to $AGENT_DIR"
mkdir -p "$AGENT_DIR"
cp -a "$SRC/." "$AGENT_DIR/"

# ---------- configuration ----------
# A Perl single-quoted string: escape \ and '.
pq() { printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/'/\\\\'/g"; }
is_local_ip() { ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$1"; }
LISTEN_IP=0.0.0.0
is_local_ip "$AGENT_IP" && LISTEN_IP="$AGENT_IP"

cat > "$AGENT_DIR/Cfg/Config.pm" <<EOF
%Cfg::Config = (
	logfile => '$(pq "$AGENT_DIR")/agent_core.log',
	listen_port => '$AGENT_PORT',
	listen_ip => '$LISTEN_IP',
	version => 'v1.4',
	key => '$(pq "$KEY")',
	steam_license => 'Accept',
	sudo_password => '$(pq "$PASSWORD")',
	web_api_url => '$(pq "$PANEL")/api.php',
	agent_event_url => '$(pq "$PANEL")/agent_event_receiver.php',
	remote_server_id => '$SERVER_ID',
	steam_dl_limit => '0',
	stats_db_host => '',
	stats_db_user => '',
	stats_db_pass => '',
	stats_db_name => '',
	stats_table_prefix => '',
	stats_frequency_minutes => '5',
);
EOF
cp "$AGENT_DIR/Cfg/Preferences.pm.default" "$AGENT_DIR/Cfg/Preferences.pm"
cat > "$AGENT_DIR/Cfg/bash_prefs.cfg" <<EOF
agent_auto_update=0
agent_update_repo_url=
agent_update_branch=
agent_update_source_path=.
run_pureftpd=0
ftp_port=${FTP_PORT:-21}
ftp_ip=0.0.0.0
ftp_pasv_range=
EOF
chmod 600 "$AGENT_DIR/Cfg/Config.pm"
chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_DIR"
chmod 750 "$AGENT_DIR/agent_core.pl" "$AGENT_DIR/agent_core_run"

# ---------- FTP (Pure-FTPd with virtual users the agent manages through pure-pw) ----------
if [ -d /etc/pure-ftpd ]; then
	say "Configuring Pure-FTPd"
	[ -s /etc/pure-ftpd/conf/PureDB ] || echo /etc/pure-ftpd/pureftpd.pdb > /etc/pure-ftpd/conf/PureDB
	ln -sf ../conf/PureDB /etc/pure-ftpd/auth/50puredb
	touch /etc/pure-ftpd/pureftpd.passwd
	pure-pw mkdb >/dev/null
	if is_local_ip "$FTP_IP"; then
		echo "$FTP_IP,${FTP_PORT:-21}" > /etc/pure-ftpd/conf/Bind
	elif [ "${FTP_PORT:-21}" != 21 ]; then
		echo ",$FTP_PORT" > /etc/pure-ftpd/conf/Bind
	fi
	systemctl restart pure-ftpd 2>/dev/null || true
fi

# ---------- service ----------
SERVICE=agent_core
[ ! -e /etc/systemd/system/agent_core.service ] || SERVICE="gse-agent-$SERVER_ID"
say "Installing the systemd service $SERVICE"
sed -e "s#{AGENT_USER}#$AGENT_USER#g" -e "s#{AGENT_PATH}#$AGENT_DIR#g" \
	-e "s#{AGENT_RUN_SCRIPT}#$AGENT_DIR/agent_core_run#g" -e "s#{AGENT_PID_FILE}#$AGENT_DIR/agent_core_run.pid#g" \
	"$AGENT_DIR/systemd/agent_core.service" > "/etc/systemd/system/$SERVICE.service"
systemctl daemon-reload
systemctl enable --now "$SERVICE.service"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
	say "Opening ports $AGENT_PORT and ${FTP_PORT:-21} in ufw"
	ufw allow "$AGENT_PORT/tcp" >/dev/null
	ufw allow "${FTP_PORT:-21}/tcp" >/dev/null
fi

say "Waiting for the agent to listen on port $AGENT_PORT"
for _ in $(seq 1 60); do
	ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$AGENT_PORT\$" && break
	sleep 2
done
ss -ltn | awk '{print $4}' | grep -q ":$AGENT_PORT\$" \
	|| die "The agent did not start. See: journalctl -u $SERVICE and $AGENT_DIR/agent_core.log"

say "Telling the panel the agent is ready"
DONE=$(panel_call done)
if [ "$(echo "$DONE" | jq -r .online)" = true ]; then
	echo
	echo "The agent is installed and the panel reached it (service $SERVICE, folder $AGENT_DIR)."
	echo "IP addresses on the panel: $(echo "$DONE" | jq -r '.ips | join(", ")')"
else
	echo
	echo "The agent is installed and running (service $SERVICE), but the panel could not reach it at $AGENT_IP:$AGENT_PORT."
	echo "Check firewalls between the panel and this machine, then open the panel's Servers page."
fi
