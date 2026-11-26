#!/usr/bin/env bash
# GSE container host setup for Linux game nodes.
#
#   gse_container_host.sh check      show what is installed (changes nothing)
#   gse_container_host.sh install    install Docker Engine (Ubuntu/Debian docker.io) and log limits
#   gse_container_host.sh firewall   apply the GSE container firewall rules now
#   gse_container_host.sh persist    install a systemd unit that re-applies the rules at boot
#   gse_container_host.sh grant-agent <user>   let the GSE agent user run docker (docker group)
#   gse_container_host.sh all        install + firewall + persist
#   gse_container_host.sh remove-firewall   remove the GSE rules (Docker stays installed)
#
# Containers on the gse-games network (bridge gse0) get full outbound internet, but cannot
# reach this host, other containers, the VPN, or any private/link-local network.
# Allowed private destinations can be listed in GSE_CONTAINER_ALLOW_PRIVATE (space separated CIDRs).
set -euo pipefail

BRIDGE="${GSE_CONTAINER_BRIDGE:-gse0}"
NETWORK="${GSE_CONTAINER_NETWORK:-gse-games}"
SUBNET="${GSE_CONTAINER_SUBNET:-172.31.240.0/20}"
CHAIN="GSE-CONTAINERS"
PRIVATE_RANGES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4"
ALLOW_PRIVATE="${GSE_CONTAINER_ALLOW_PRIVATE:-}"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }; }

check() {
	echo "docker: $(command -v docker || echo missing)"
	if command -v docker >/dev/null; then
		docker version --format 'engine {{.Server.Version}}' 2>/dev/null || echo "engine: not reachable"
		docker info --format 'cgroup v{{.CgroupVersion}} driver={{.CgroupDriver}} security={{.SecurityOptions}}' 2>/dev/null || true
		docker network inspect "$NETWORK" --format 'network {{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}} icc={{index .Options "com.docker.network.bridge.enable_icc"}}' 2>/dev/null || echo "network $NETWORK: missing"
	fi
	iptables -S "$CHAIN" 2>/dev/null | sed 's/^/rule: /' || echo "firewall chain $CHAIN: missing"
	command -v ufw >/dev/null && ufw status 2>/dev/null | head -1 || true
}

install_docker() {
	need_root
	if ! command -v docker >/dev/null; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -q
		apt-get install -y -q docker.io
	fi
	mkdir -p /etc/docker
	if [ ! -f /etc/docker/daemon.json ]; then
		# Bounded logs and no privilege gain for every container; containers survive a daemon restart.
		cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "no-new-privileges": true
}
JSON
	fi
	systemctl enable --now docker
	systemctl restart docker
	if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
		docker network create --driver bridge --subnet "$SUBNET" \
			--opt com.docker.network.bridge.enable_icc=false \
			--opt com.docker.network.bridge.name="$BRIDGE" \
			--label gse.managed=true "$NETWORK"
	fi
}

firewall() {
	need_root
	# Forwarded traffic from containers (Docker evaluates DOCKER-USER first).
	iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
	iptables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
	for cidr in $ALLOW_PRIVATE; do
		iptables -A "$CHAIN" -d "$cidr" -j RETURN
	done
	for cidr in $PRIVATE_RANGES; do
		iptables -A "$CHAIN" -d "$cidr" -j DROP
	done
	iptables -A "$CHAIN" -j RETURN
	iptables -N DOCKER-USER 2>/dev/null || true
	iptables -C DOCKER-USER -i "$BRIDGE" -j "$CHAIN" 2>/dev/null || iptables -I DOCKER-USER 1 -i "$BRIDGE" -j "$CHAIN"
	# Traffic from containers to this host itself (agent, SSH, MySQL, panel, anything listening).
	iptables -C INPUT -i "$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
		|| iptables -I INPUT 1 -i "$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -C INPUT -i "$BRIDGE" -j DROP 2>/dev/null || iptables -I INPUT 2 -i "$BRIDGE" -j DROP
	# No IPv6 on the game network; make sure nothing slips through if it is enabled later.
	if command -v ip6tables >/dev/null; then
		ip6tables -C INPUT -i "$BRIDGE" -j DROP 2>/dev/null || ip6tables -I INPUT 1 -i "$BRIDGE" -j DROP || true
		ip6tables -C FORWARD -i "$BRIDGE" -j DROP 2>/dev/null || ip6tables -I FORWARD 1 -i "$BRIDGE" -j DROP || true
	fi
	echo "GSE container firewall applied on $BRIDGE."
}

remove_firewall() {
	need_root
	iptables -D DOCKER-USER -i "$BRIDGE" -j "$CHAIN" 2>/dev/null || true
	iptables -D INPUT -i "$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
	iptables -D INPUT -i "$BRIDGE" -j DROP 2>/dev/null || true
	iptables -F "$CHAIN" 2>/dev/null || true
	iptables -X "$CHAIN" 2>/dev/null || true
	ip6tables -D INPUT -i "$BRIDGE" -j DROP 2>/dev/null || true
	ip6tables -D FORWARD -i "$BRIDGE" -j DROP 2>/dev/null || true
	echo "GSE container firewall removed."
}

persist() {
	need_root
	install -m 0755 "$(readlink -f "$0")" /usr/local/sbin/gse_container_host.sh
	cat > /etc/systemd/system/gse-container-firewall.service <<UNIT
[Unit]
Description=GSE game container firewall
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=GSE_CONTAINER_ALLOW_PRIVATE=$ALLOW_PRIVATE
ExecStart=/usr/local/sbin/gse_container_host.sh firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
	systemctl daemon-reload
	systemctl enable gse-container-firewall.service
}

grant_agent() {
	need_root
	local user="${1:-}"
	[ -n "$user" ] && id "$user" >/dev/null 2>&1 || { echo "Usage: $0 grant-agent <agent user>" >&2; exit 2; }
	# The docker group is root-equivalent. Only the agent user gets it, never game users.
	case "$user" in gamehome*) echo "Refusing: $user is a game server user." >&2; exit 1 ;; esac
	usermod -aG docker "$user"
	echo "$user can use docker after the agent restarts."
}

case "${1:-check}" in
	check) check ;;
	install) install_docker ;;
	firewall) firewall ;;
	persist) persist ;;
	remove-firewall) remove_firewall ;;
	grant-agent) grant_agent "${2:-}" ;;
	all) install_docker; firewall; persist; check ;;
	*) sed -n '2,14p' "$0"; exit 2 ;;
esac
