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

cat <<'EOF'

Prerequisite installation finished.

Notes:
- MIME::Base64, File::Basename, and Getopt::Long are Perl core modules and are not installed as separate apt packages.
- Crypt::XXTEA is bundled in this repository under Crypt/XXTEA.pm, so libcrypt-xxtea-perl is not required from apt.
- needrestart messages about services or VM guests are normal package-manager output after dependency installation.
EOF
