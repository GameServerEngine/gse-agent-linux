#!/usr/bin/perl
# GameManagerLinux: the parsers, the scripts it writes, and a real run. The real run uses the
# shared GameManager.pm with the Linux checks against a fake game (a program that listens on a
# UDP port) in screen, as the current user (the runner runs commands without sudo here).
use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/..";
use GameManager;
use GameManagerLinux;

# ---- parsers ----
my $table = GameManagerLinux::parse_proc_table(join("\n",
	"GSE-PROC 1",
	"10\t1\tscreen\t/usr/bin/screen\t/home/a/GSP\tSCREEN -D -m -S SCREEN_HOME_000000952",
	"11\t10\tbash\t/usr/bin/bash\t/home/a/952/gamefiles\tbash /home/a/952/serverStart.sh",
	"12\t11\tQuake3-UrT-Ded.\t/home/a/952/gamefiles/Quake3-UrT-Ded.x86_64\t/home/a/952/gamefiles\t./Quake3-UrT-Ded.x86_64 +set dedicated 2",
	"13\t11\tjava\t/usr/lib/jvm/bin/java\t/home/a/953/gamefiles\tjava -jar server.jar",
	"14\t1\tQuake3-UrT-Ded.\t/home/a/951/gamefiles/Quake3-UrT-Ded.x86_64\t/home/a/951/gamefiles\t./Quake3-UrT-Ded.x86_64",
	"") . "\n");
is(scalar(@$table), 5, 'process table: five rows');
is(GameManagerLinux::parse_proc_table("garbage"), undef, 'process table: unknown text is undef, not empty');
is(GameManagerLinux::row_path($table->[2]), '/home/a/952/gamefiles/Quake3-UrT-Ded.x86_64', 'a game binary runs from its own path');
is(GameManagerLinux::row_path($table->[3]), '/home/a/953/gamefiles/java', 'java runs from its working folder');
ok(GameManagerLinux::row_matches($table->[0], 'screen'), 'the launcher matches "screen"');
ok(GameManagerLinux::row_matches($table->[2], '/home/a/952/gamefiles/./Quake3-UrT-Ded.x86_64'), 'the game matches its full path');
ok(!GameManagerLinux::row_matches($table->[1], 'Quake3-UrT-Ded.x86_64'), 'bash is not the game');
is_deeply(GameManagerLinux::pids_in_dir($table, 'Quake3-UrT-Ded.x86_64', '/home/a/952/gamefiles'), [12], 'copies in this folder only');
is_deeply([GameManagerLinux::parse_descendants($table, 10)], [11, 12, 13], 'descendants of the launcher, nearest first');

my $ss = join("\n",
	'udp   UNCONN 0      0      173.208.136.11:27960      0.0.0.0:*    users:(("Quake3-UrT-Ded.",pid=912060,fd=2))',
	'tcp   LISTEN 0      5           127.0.0.1:12679      0.0.0.0:*    users:(("perl",pid=837868,fd=4))',
	'tcp   ESTAB  0      0      173.208.136.11:27960      1.2.3.4:5000 users:(("x",pid=99,fd=1))',
	'');
is_deeply([GameManagerLinux::parse_ss_owners($ss, 27960)], [912060], 'UDP port owner; an established TCP row is not a listener');
is_deeply([GameManagerLinux::parse_ss_owners($ss, 2796)], [], 'a shorter port number does not match');
is(GameManagerLinux::parse_ss_listening($ss, 12679), 1, 'TCP listener found');
is(GameManagerLinux::parse_ss_listening($ss, 1), 0, 'nothing on another port');

# ---- shared GameManager with the Linux settings ----
is(GameManager::_path_inside('/home/A/952/x', '/home/a/952', 0), 0, 'Linux: folder names keep their case');
is(GameManager::_path_inside('C:/A/952/x', 'c:/a/952', 1), 1, 'Windows: folder names ignore case');

# ---- a real run ----
my $root = tempdir(CLEANUP => 1);
my $home = "$root/952";
mkdir $home; mkdir "$home/gamefiles"; mkdir "$root/screenlogs";
my $port = 20000 + int(rand(20000));
open(my $g, '>', "$home/gamefiles/fakegame") or die;
print $g "#!/usr/bin/env python3\nimport socket,sys,time\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\ns.bind(('127.0.0.1',int(sys.argv[1])))\nwhile True: time.sleep(1)\n";
close $g; chmod 0755, "$home/gamefiles/fakegame";
open(my $rc, '>', "$root/screenrc") or die; print $rc "startup_message off\n"; close $rc;

GameManagerLinux::set_helper("$FindBin::Bin/../gm_proc_table.pl");
GameManagerLinux::set_runner(sub {
	my ($cmd) = @_;
	my $out = `bash -c @{[GameManagerLinux::sh_quote($cmd)]} 2>/dev/null`;
	return ($out, '');
});
my $screen_id = "GSE_TEST_$$";
my @log;
my $gm = GameManager->new(
	state_dir => $root, dir_for => sub { "$root/$_[0]" }, agent_dir => $root,
	pid_alive => \&GameManagerLinux::pid_alive,
	pid_executable_matches => \&GameManagerLinux::pid_executable_matches,
	port_listening => \&GameManagerLinux::port_listening,
	port_owner_pids => \&GameManagerLinux::port_owner_pids,
	pid_path => \&GameManagerLinux::pid_exe_path,
	child_pids => \&GameManagerLinux::child_pids,
	find_pid_in_dir => \&GameManagerLinux::find_pid_in_dir,
	list_dir_pids => \&GameManagerLinux::find_all_pids_in_dir,
	kill_pid => \&GameManagerLinux::kill_pid,
	executable_exists => \&GameManagerLinux::executable_exists,
	launch => sub { my ($c, $w, $o) = @_; return GameManagerLinux::launch_screen(script => $o->{script}, screen_id => $screen_id, screenrc => "$root/screenrc", run_dir => $root); },
	script_ext => '.sh', write_script => \&GameManagerLinux::write_server_script,
	write_admin_script => \&GameManagerLinux::write_admin_script,
	launcher_image => 'screen', shell_images => ['screen', 'bash', 'sh'], fold_case => 0,
	log => sub { push @log, $_[0] }, startup_timeout => 20,
);
sub wait_state { my ($want, $secs) = @_; for (1 .. $secs) { GameManagerLinux::forget_process_table(); $gm->tick(952); return 1 if $gm->read_state(952)->{state} eq $want; sleep 1; } return 0; }
sub game_pids { return grep { $_ } split /\n/, `pgrep -f "[f]akegame $port"`; }

my $r = $gm->start(952, command => "\"$home/gamefiles/fakegame\" $port", workdir => "$home/gamefiles", port => $port);
ok($r->{ok}, 'start launches the game in screen');
ok(-x "$home/serverStart.sh" && -x "$home/startserver.sh" && -x "$home/stopserver.sh", 'serverStart.sh, startserver.sh and stopserver.sh written');
ok(wait_state('RUNNING', 15), 'RUNNING once the game holds its port');
my $pid = $gm->read_state(952)->{pid};
ok($pid && (grep { $_ == $pid } game_pids()), 'the saved PID is the game itself, not screen or bash');

kill 'KILL', $pid;
ok(wait_state('STARTING', 15) || $gm->read_state(952)->{state} eq 'RUNNING', 'a killed game is restarted');
ok(wait_state('RUNNING', 15), 'and is RUNNING again');
my @crashes = grep { /\d/ } split /,/, ($gm->read_state(952)->{crashes} // '');
is(scalar(@crashes), 1, 'the kill counted as one crash');
is(scalar(game_pids()), 1, 'exactly one copy of the game');

my $s = $gm->stop(952);
ok($s->{ok}, 'stop frees the port');
is($gm->read_state(952)->{state}, 'STOPPED', 'state STOPPED');
is(scalar(game_pids()), 0, 'no game left');
diag(`screen -ls 2>&1`);
ok(!`screen -ls | grep $screen_id | grep -v Dead`, 'no screen left');
GameManagerLinux::forget_process_table();
$gm->tick(952);
is($gm->read_state(952)->{state}, 'STOPPED', 'a check after Stop does not start it again');
like(`cat $home/last-start.txt`, qr/start/, 'last-start.txt records the start');

system("pkill -f 'fakegame $port' 2>/dev/null; screen -S $screen_id -X quit >/dev/null 2>&1");
done_testing();
