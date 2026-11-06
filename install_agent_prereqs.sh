#!/usr/bin/env bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "This script installs OS packages and must be run as root."
	echo "Run: sudo ./install_agent_prereqs.sh"
	exit 1
fi

if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
	echo "This prerequisite installer currently supports apt/dpkg systems only."
	echo "Install equivalent Perl, screen, rsync, sudo, unzip, git, curl, and FTP packages manually."
	exit 1
fi

echo "Installing GSE Linux Agent prerequisites for Debian/Ubuntu."
echo "Package manager output from needrestart about services, VM guests, or kernel state is normal OS maintenance output."

apt-get update

required_packages=(
	perl
	libxml-parser-perl
	libpath-class-perl
	libarchive-extract-perl
	libarchive-zip-perl
	libhttp-daemon-perl
	libfrontier-rpc-perl
	libfile-copy-recursive-perl
	libschedule-cron-perl
	libio-compress-perl
	libcompress-raw-zlib-perl
	libfile-find-rule-perl
	libwww-perl
	screen
	rsync
	sudo
	e2fsprogs
	unzip
	subversion
	git
	curl
	ca-certificates
	bzip2
	pure-ftpd
	libc6
)

optional_packages=(
	libdbi-perl
	libdbd-mysql-perl
	libfcgi-perl
	apache2
	php
	php-mysql
)

apt-get install -y "${required_packages[@]}"

for pkg in "${optional_packages[@]}"; do
	if ! apt-get install -y "$pkg"; then
		echo "Warning: optional package ${pkg} could not be installed."
	fi
done

echo
echo "32-bit compatibility packages are useful for some legacy SteamCMD/game-server binaries."
read -r -p "Enable i386 architecture and install 32-bit compatibility packages? [yes]: " install_i386
install_i386="${install_i386:-yes}"
if [[ "$install_i386" =~ ^[Yy]([Ee][Ss])?$ ]]; then
	if ! dpkg --print-foreign-architectures | grep -qx i386; then
		dpkg --add-architecture i386
		apt-get update
	fi
	for pkg in libc6-i386 lib32gcc-s1 libgcc-s1:i386; do
		if ! apt-get install -y "$pkg"; then
			echo "Warning: optional 32-bit package ${pkg} could not be installed."
		fi
	done
fi

# restic for customer backups: pinned release, checked against the upstream SHA256SUMS value.
# Set RESTIC_OFFLINE_BZ2 to a local copy of the release file for an offline install.
RESTIC_VERSION=0.19.1
RESTIC_BZ2_SHA256=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
RESTIC_BZ2_URL="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2"
RESTIC_INSTALL_PATH="${RESTIC_INSTALL_PATH:-/usr/local/bin/restic}"

install_restic()
{
	if [ -x "$RESTIC_INSTALL_PATH" ] && "$RESTIC_INSTALL_PATH" version 2>/dev/null | grep -q "restic ${RESTIC_VERSION} "; then
	    echo "restic ${RESTIC_VERSION} is already installed at ${RESTIC_INSTALL_PATH}."
	    return 0
	fi
	local work
	work="$(mktemp -d)"
	if [ -n "${RESTIC_OFFLINE_BZ2:-}" ]; then
	    cp "$RESTIC_OFFLINE_BZ2" "$work/restic.bz2" || return 1
	else
	    curl -fsSL --retry 3 --connect-timeout 20 -o "$work/restic.bz2" "$RESTIC_BZ2_URL" || { rm -rf "$work"; echo "Could not download restic from ${RESTIC_BZ2_URL}." >&2; return 1; }
	fi
	if ! echo "${RESTIC_BZ2_SHA256}  ${work}/restic.bz2" | sha256sum -c - >/dev/null 2>&1; then
	    rm -rf "$work"
	    echo "The restic download does not match the pinned sha256. Nothing was installed." >&2
	    return 1
	fi
	bunzip2 -c "$work/restic.bz2" > "$work/restic" || { rm -rf "$work"; return 1; }
	install -m 755 "$work/restic" "$RESTIC_INSTALL_PATH" || { rm -rf "$work"; return 1; }
	rm -rf "$work"
	"$RESTIC_INSTALL_PATH" version | head -n 1
}

echo
echo "Installing restic ${RESTIC_VERSION} for customer backups."
install_restic || { echo "restic install failed." >&2; exit 1; }

cat <<'EOF'

Prerequisite installation finished.

Notes:
- MIME::Base64, File::Basename, and Getopt::Long are Perl core modules and are not installed as separate apt packages.
- Crypt::XXTEA is bundled in this repository under Crypt/XXTEA.pm, so libcrypt-xxtea-perl is not required from apt.
- needrestart messages about services or VM guests are normal package-manager output after dependency installation.
EOF
