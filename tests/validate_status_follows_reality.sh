#!/usr/bin/env bash
# The watchdog (serverStart.sh), startserver.sh and stopserver.sh must keep the status files true,
# whoever starts or stops the game: the panel, the agent, or an admin on the host.
# Builds the scripts with the real generator from agent_core.pl, then runs them with a fake game
# (a program that listens on a port) in a throw-away home folder.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/gse-reality.XXXXXX)"
home="$work/home"; mkdir -p "$home"
port=$((20000 + RANDOM % 20000))
id="SCREEN_TEST_$$"
fails=0
ok()   { echo "ok - $1"; }
fail() { echo "not ok - $1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else fail "$1"; fi; }
games() { pgrep -f "gse_fakegame $port" | wc -l; }
cleanup() { pkill -f "gse_fakegame $port" 2>/dev/null; screen -S "$id" -X quit >/dev/null 2>&1; [ -f "$home/watchdog.pid" ] && kill "$(cat "$home/watchdog.pid")" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

cat > "$work/gse_fakegame.py" <<PY
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(1); time.sleep(600)
PY
py="$(command -v python3)"
cp "$work/gse_fakegame.py" "$home/gse_fakegame.py"

# Build serverStart.sh, startserver.sh and stopserver.sh with the generator from agent_core.pl.
perl - "$root/agent_core.pl" "$home" "$id" "$port" "$py" <<'PERL' || { echo "could not build the scripts"; exit 1; }
use strict; use warnings;
my ($core, $home, $id, $port, $py) = @ARGV;
open(my $fh, '<', $core) or die; local $/; my $src = <$fh>; close $fh;
my $code = '';
for my $name (qw(shell_single_quote create_screen_cmd_loop)) {
    $src =~ /^(sub $name\n\{.*?^\})$/ms or die "sub $name not found"; $code .= "$1\n";
}
use constant SCREENRC_FILE => '/dev/null';
sub replace_Env_Vars { return $_[3] }
sub secure_path_without_decrypt { 1 }
sub sudo_exec_without_decrypt { 1 }
eval $code; die $@ if $@;
create_screen_cmd_loop($id, "$py gse_fakegame.py $port gse_fakegame $port", "", undef, undef, $home, $home, $port);
PERL
bash -n "$home/serverStart.sh" && ok "serverStart.sh is valid bash" || fail "serverStart.sh is valid bash"
check "startserver.sh and stopserver.sh are written and short" '[ -x "$home/startserver.sh" ] && [ -x "$home/stopserver.sh" ] && [ "$(wc -l < "$home/startserver.sh")" -le 3 ]'

# The fake game must be found by "gse_fakegame <port>" in its command line, so pass that as extra args.
# (The generator ran it as: python3 gse_fakegame.py <port> gse_fakegame <port>.)
waitfor() { for _ in $(seq 1 "${2:-20}"); do eval "$1" && return 0; sleep 1; done; return 1; }
listening() { ss -H -lnt 2>/dev/null | grep -Eq "[:.]$port[[:space:]]"; }
pidfile_alive() { [ -r "$home/$1" ] && kill -0 "$(cat "$home/$1")" 2>/dev/null; }

# 1. Start by an admin on the host.
bash "$home/startserver.sh" 2>/dev/null
check "start: RUNNING is recorded, STOPPED is not" '[ -r "$home/status.running" ] && [ ! -e "$home/status.stopped" ]'
check "start: the game comes up and listens"        'waitfor listening 20'
check "start: watchdog and game pids are recorded"   'waitfor "pidfile_alive watchdog.pid && pidfile_alive game.pid" 10'
check "start: exactly one game"                      '[ "$(games)" -eq 1 ]'

# 2. A second start does not start a second game.
bash "$home/startserver.sh" 2>/dev/null
sleep 3
check "second start: still exactly one game" '[ "$(games)" -eq 1 ]'

# 3. The watchdog dies but the game lives on: a new start takes the game over, not a second copy.
game_before="$(cat "$home/game.pid")"
kill -9 "$(cat "$home/watchdog.pid")"; screen -S "$id" -X quit >/dev/null 2>&1; rm -f "$home/game.pid"
bash "$home/startserver.sh" 2>/dev/null
check "adopt: the live game is recorded again, same pid" 'waitfor "[ \"\$(cat \"$home/game.pid\" 2>/dev/null)\" = \"$game_before\" ]" 15'
check "adopt: still exactly one game"                    '[ "$(games)" -eq 1 ]'

# 4. Stop by an admin on the host.
bash "$home/stopserver.sh" 2>/dev/null
check "stop: STOPPED is recorded, RUNNING is not" '[ -r "$home/status.stopped" ] && [ ! -e "$home/status.running" ]'
check "stop: the game is gone and the port is closed" 'waitfor "! listening" 10 && [ "$(games)" -eq 0 ]'
check "stop: the watchdog and the screen session are gone" '! pidfile_alive watchdog.pid && ! screen -ls 2>/dev/null | grep -q "$id"'
sleep 2
check "stop: it stays stopped (nothing relaunches it)" '[ "$(games)" -eq 0 ] && ! listening'

# 5. A game started by hand, with no watchdog and no pid files: start adopts it, stop ends it.
rm -f "$home"/*.pid "$home/game.launch_ts"
setsid "$py" "$home/gse_fakegame.py" "$port" gse_fakegame "$port" >/dev/null 2>&1 &
waitfor listening 10
bash "$home/startserver.sh" 2>/dev/null
sleep 3
check "hand-started: not launched a second time" '[ "$(games)" -eq 1 ]'
check "hand-started: its pid is recorded"        '[ "$(cat "$home/game.pid" 2>/dev/null)" = "$(pgrep -f "gse_fakegame $port" | head -1)" ]'
bash "$home/stopserver.sh" 2>/dev/null
check "hand-started: stop ends it" 'waitfor "! listening" 10 && [ "$(games)" -eq 0 ]'

echo "$fails failed"
[ "$fails" -eq 0 ]
