#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$repo_root/steamcmd_linux.tar.gz"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

expected_entries="$(
	cat <<'EOF'
linux32/crashhandler.so
linux32/libstdc++.so.6
linux32/steamcmd
linux32/steamerrorreporter
steamcmd.sh
EOF
)"

expected_files="$(
	cat <<'EOF'
steamcmd/linux32/crashhandler.so
steamcmd/linux32/libstdc++.so.6
steamcmd/linux32/steamcmd
steamcmd/linux32/steamerrorreporter
steamcmd/steamcmd.sh
EOF
)"

require_file() {
	[ -f "$1" ] || fail "missing file: ${1#$repo_root/}"
}

while IFS= read -r file; do
	require_file "$repo_root/$file"
done <<< "$expected_files"

[ -x "$repo_root/steamcmd/steamcmd.sh" ] || fail "steamcmd/steamcmd.sh is not executable"
[ -x "$repo_root/steamcmd/linux32/steamcmd" ] || fail "steamcmd/linux32/steamcmd is not executable"

actual_files="$(find "$repo_root/steamcmd" -mindepth 1 -type f -printf '%P\n' | sed 's#^#steamcmd/#' | sort)"
[ "$actual_files" = "$expected_files" ] || {
	printf 'Expected files:\n%s\nActual files:\n%s\n' "$expected_files" "$actual_files" >&2
	fail "steamcmd/ contains unexpected files"
}

if [ -f "$archive" ]; then
	gzip -t "$archive"
	archive_entries="$(tar -tzf "$archive" | sort)"
	[ "$archive_entries" = "$expected_entries" ] || {
		printf 'Expected archive entries:\n%s\nActual archive entries:\n%s\n' "$expected_entries" "$archive_entries" >&2
		fail "archive contains unexpected entries"
	}
	while IFS= read -r entry; do
		case "$entry" in
			""|/*|*..*|*\\*|*.exe|*.dll|*.bat|*.cmd|*.ps1)
				fail "archive contains suspicious path: $entry"
				;;
		esac
	done <<< "$archive_entries"

	tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gse-steamcmd-archive.XXXXXX")"
	trap 'rm -rf "$tmpdir"' EXIT
	tar -xzf "$archive" -C "$tmpdir"
	while IFS= read -r entry; do
		cmp -s "$tmpdir/$entry" "$repo_root/steamcmd/$entry" || fail "archive entry differs from tracked bootstrap: $entry"
	done <<< "$expected_entries"
fi

git -C "$repo_root" ls-files steamcmd | sort | diff -u <(printf '%s\n' "$expected_files") - >/dev/null || fail "tracked SteamCMD file set is unexpected"

echo "SteamCMD bootstrap payload validation passed."
