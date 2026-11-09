#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent="$repo_root/agent_core.pl"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

require_text() {
	local pattern="$1"
	grep -Fq -- "$pattern" "$agent" || fail "missing lifecycle game-key contract source: $pattern"
}

require_absent_text() {
	local pattern="$1"
	if grep -Fq -- "$pattern" "$agent"; then
		fail "unexpected lifecycle game-key contract source remains: $pattern"
	fi
}

line_for() {
	local pattern="$1"
	local line
	line="$(grep -nF -- "$pattern" "$agent" | head -n 1 | cut -d: -f1)"
	[ -n "$line" ] || fail "missing ordered source: $pattern"
	printf '%s\n' "$line"
}

require_order() {
	local before_pattern="$1"
	local after_pattern="$2"
	local before_line
	local after_line
	before_line="$(line_for "$before_pattern")"
	after_line="$(line_for "$after_pattern")"
	[ "$before_line" -lt "$after_line" ] || fail "'$before_pattern' must appear before '$after_pattern'"
}

perl -0ne '
	my $source = $_;
	$source =~ /(sub normalize_agent_path_without_decrypt\s*\{.*?)(?=\nsub process_associated_with_home_without_decrypt\s*\{)/s
		or die "cannot extract game-key path helper block\n";
	eval $1;
	die $@ if $@;

	sub assert_ok {
		my ($condition, $message) = @_;
		die "$message\n" unless $condition;
	}

	my ($ok, $game_root, $error) = resolve_game_root_without_decrypt("/srv/games/42", "arma3_linux64");
	assert_ok($ok && $game_root eq "/srv/games/42/arma3_linux64", "valid game_key derives game_root");

	for my $bad_key ("", " ../ark", "../ark", "ark/evil", "ark\\evil", "ark:evil", "ark..evil", "bad key", "CON", "LPT1", "game.") {
		my ($bad_ok, undef, $bad_error) = resolve_game_root_without_decrypt("/srv/games/42", $bad_key);
		assert_ok(!$bad_ok && $bad_error ne "", "unsafe game_key was rejected: $bad_key");
	}

	my ($prefixed_ok, $prefixed_path) = resolve_game_payload_path_without_decrypt("/srv/games/42", "arma3_linux64", "arma3_linux64/bin");
	assert_ok($prefixed_ok && $prefixed_path eq "/srv/games/42/arma3_linux64/bin", "Panel game_key-prefixed run_dir resolves once");

	my ($relative_ok, $relative_path) = resolve_game_payload_path_without_decrypt("/srv/games/42", "arma3_linux64", "bin");
	assert_ok($relative_ok && $relative_path eq "/srv/games/42/arma3_linux64/bin", "relative run_dir resolves beneath game_root");

	for my $bad_path ("../escape", "/srv/other", "C:/escape", "bin/../../escape") {
		my ($path_ok, undef, $path_error) = resolve_game_payload_path_without_decrypt("/srv/games/42", "arma3_linux64", $bad_path);
		assert_ok(!$path_ok && $path_error ne "", "unsafe payload path was rejected: $bad_path");
	}
' "$agent" || fail "game-key helper behavior failed"

perl -0ne '
	use File::Temp qw(tempdir);
	my $source = $_;
	$source =~ /(sub desired_state_paths_without_decrypt\s*\{.*?)(?=\n# Remove lifecycle PID\/timestamp metadata)/s
		or die "cannot extract desired-state helper block\n";
	eval $1;
	die $@ if $@;

	sub assert_ok {
		my ($condition, $message) = @_;
		die "$message\n" unless $condition;
	}

	my $home = tempdir(CLEANUP => 1);
	my ($state, $reason) = read_desired_state_without_decrypt($home);
	assert_ok($state eq "stopped" && $reason eq "missing", "missing marker fails safe as stopped");

	assert_ok(write_desired_state_without_decrypt($home, "running"), "running marker writes successfully");
	($state, $reason) = read_desired_state_without_decrypt($home);
	assert_ok($state eq "running" && $reason eq "ok", "valid running marker is accepted");

	open(my $BAD, ">", "$home/status.running") or die $!;
	print {$BAD} "not-a-valid-marker\n";
	close($BAD);
	($state, $reason) = read_desired_state_without_decrypt($home);
	assert_ok($state eq "stopped" && $reason eq "invalid", "malformed running marker fails safe as stopped");

	open(my $MISMATCH, ">", "$home/status.running") or die $!;
	print {$MISMATCH} "123,stopped\n";
	close($MISMATCH);
	($state, $reason) = read_desired_state_without_decrypt($home);
	assert_ok($state eq "stopped" && $reason eq "invalid", "mismatched running marker content fails safe as stopped");

	assert_ok(write_desired_state_without_decrypt($home, "stopped"), "stopped marker writes successfully");
	($state, $reason) = read_desired_state_without_decrypt($home);
	assert_ok($state eq "stopped" && $reason eq "ok", "valid stopped marker is accepted");

	open(my $RUNNING, ">", "$home/status.running") or die $!;
	print {$RUNNING} "123,running\n";
	close($RUNNING);
	($state, $reason) = read_desired_state_without_decrypt($home);
	assert_ok($state eq "stopped" && $reason eq "conflicting", "conflicting markers fail safe as stopped");
' "$agent" || fail "desired-state helper behavior failed"

perl <<'PERL' || exit 1
use strict;
use warnings;

sub assert_ok {
	my ($condition, $message) = @_;
	die "FAIL: $message\n" unless $condition;
}

sub safe_game_key {
	my ($key) = @_;
	return 0 if !defined($key) || $key eq "" || $key ne do { my $tmp = $key; $tmp =~ s/^\s+|\s+$//gr };
	return 0 if $key =~ /[\x00-\x1F\x7F]/;
	return 0 if $key =~ m{[\\/]} || $key =~ /^[A-Za-z]:/ || index($key, ":") >= 0;
	return 0 if $key eq "." || $key eq ".." || index($key, "..") >= 0;
	return 0 if $key !~ /^[A-Za-z0-9._-]+$/ || substr($key, -1) eq ".";
	my ($name) = split(/\./, uc($key), 2);
	my %reserved = map { $_ => 1 } qw(CON PRN AUX NUL CONIN$ CONOUT$ COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9 LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9);
	return !$reserved{$name};
}

{
	package FakeLifecycle;
	sub new {
		return bless {
			now => 1000,
			files => {},
			pids => {},
			next_pid => 100,
			screen => 0,
			tcp => {},
			udp => {},
			protected => {},
			ambiguous => {},
			management_home => "/srv/homes/42",
			game_key => "arma3_linux64",
			game_root => "/srv/homes/42/arma3_linux64",
			game_group => 0,
			bot_group => 0,
			watchdog_group => 0,
			watchdog_content => "",
		}, shift;
	}
	sub write { $_[0]->{files}->{$_[1]} = $_[2] }
	sub exists { exists $_[0]->{files}->{$_[1]} }
	sub unlink { delete $_[0]->{files}->{$_[1]} }
	sub spawn {
		my ($self, $role, $safe) = @_;
		my $pid = $self->{next_pid}++;
		$self->{pids}->{$pid} = { role => $role, safe => $safe ? 1 : 0, alive => 1, group => $pid };
		return $pid;
	}
	sub kill_group {
		my ($self, $pid) = @_;
		return if !$pid || !$self->{pids}->{$pid};
		my $group = $self->{pids}->{$pid}->{group};
		for my $candidate (keys %{$self->{pids}}) {
			$self->{pids}->{$candidate}->{alive} = 0 if $self->{pids}->{$candidate}->{group} == $group;
		}
	}
	sub alive {
		my ($self, $pid) = @_;
		return $pid && $self->{pids}->{$pid} && $self->{pids}->{$pid}->{alive};
	}
	sub status_running {
		my ($self) = @_;
		return $self->exists("$self->{management_home}/status.running") && !$self->exists("$self->{management_home}/status.stopped");
	}
	sub set_state {
		my ($self, $state) = @_;
		$self->unlink("$self->{management_home}/status.running");
		$self->unlink("$self->{management_home}/status.stopped");
		$self->write("$self->{management_home}/status.$state", "$self->{now},$state");
	}
	sub cleanup {
		my ($self, $force) = @_;
		$self->set_state("stopped");
		$self->{screen} = 0;
		for my $name (qw(watchdog.pid bot.pid game.pid)) {
			my $pid = $self->{files}->{"$self->{management_home}/$name"} || 0;
			$self->kill_group($pid);
		}
		for my $proto (qw(tcp udp)) {
			for my $port (keys %{$self->{$proto}}) {
				my $pid = $self->{$proto}->{$port};
				return (0, "protected_port_owner") if $self->{protected}->{$pid};
				return (0, "ambiguous_port_owner") if $self->{ambiguous}->{$pid};
				$self->kill_group($pid);
				delete $self->{$proto}->{$port};
			}
		}
		$self->unlink("$self->{management_home}/watchdog.pid");
		$self->unlink("$self->{management_home}/bot.pid");
		$self->unlink("$self->{management_home}/game.pid");
		$self->unlink("$self->{management_home}/game.launch_ts");
		return (1, "STOPPED");
	}
	sub start {
		my ($self, %opts) = @_;
		return (0, "invalid_game_key") unless main::safe_game_key($self->{game_key});
		my ($clean_ok, $clean_status) = $self->cleanup(0);
		return (0, $clean_status) unless $clean_ok;
		$self->{watchdog_content} = join("|", $opts{command} || "", $opts{env} || "", $opts{run_dir} || "");
		$self->write("$self->{management_home}/serverStart.sh", $self->{watchdog_content});
		$self->set_state("running");
		$self->{screen} = 1;
		my $watchdog = $self->spawn("watchdog", 1);
		my $game = $self->spawn("game", 1);
		$self->{watchdog_group} = $watchdog;
		$self->{game_group} = $game;
		$self->write("$self->{management_home}/watchdog.pid", $watchdog);
		$self->write("$self->{management_home}/game.pid", $game);
		$self->write("$self->{management_home}/game.launch_ts", $self->{now});
		if($opts{bot}) {
			my $bot = $self->spawn("bot", 1);
			$self->{bot_group} = $bot;
			$self->write("$self->{management_home}/bot.def", "workdir=$self->{game_root}/bot\ncommand=bot\n");
			$self->write("$self->{management_home}/bot.pid", $bot);
		}
		return (1, "STARTED");
	}
	sub watchdog_tick {
		my ($self) = @_;
		return if !$self->status_running;
		my $game = $self->{files}->{"$self->{management_home}/game.pid"};
		if(!$self->alive($game)) {
			my $launch = $self->{files}->{"$self->{management_home}/game.launch_ts"} || 0;
			if($self->{now} - $launch < 120) {
				$self->cleanup(1);
				return;
			}
			$game = $self->spawn("game", 1);
			$self->{game_group} = $game;
			$self->write("$self->{management_home}/game.pid", $game);
			$self->write("$self->{management_home}/game.launch_ts", $self->{now});
		}
		my $bot = $self->{files}->{"$self->{management_home}/bot.pid"};
		if($self->exists("$self->{management_home}/bot.def") && !$self->alive($bot)) {
			$bot = $self->spawn("bot", 1);
			$self->{bot_group} = $bot;
			$self->write("$self->{management_home}/bot.pid", $bot);
		}
	}
	sub stop { $_[0]->cleanup(0) }
	sub force_stop { $_[0]->cleanup(1) }
	sub restart {
		my ($self, %opts) = @_;
		my ($stop_ok, $stop_status) = $self->stop;
		return (0, $stop_status) unless $stop_ok;
		return $self->start(%opts);
	}
	sub startup_replay {
		my ($self) = @_;
		return $self->status_running ? $self->start(command => "replay") : (0, "desired_stopped");
	}
	sub management_files_under_game_root {
		my ($self) = @_;
		my @bad = grep {
			index($_, "$self->{game_root}/") == 0 &&
			$_ =~ m{/(?:serverStart\.sh|status\.(?:running|stopped)|watchdog\.pid|bot\.pid|game\.pid|bot\.def|_game_content|secure\.sh|preinstall\.sh|postinstall\.sh|runinstall\.sh)$}
		} keys %{$self->{files}};
		return @bad;
	}
}

my $fresh = FakeLifecycle->new;
my ($ok, $status) = $fresh->start(command => "alpha", env => "A=1", run_dir => "arma3_linux64/bin");
assert_ok($ok && $fresh->{screen} && $fresh->exists("$fresh->{management_home}/serverStart.sh"), "fresh Start launches one managed watchdog");
assert_ok(scalar($fresh->management_files_under_game_root) == 0, "fresh Start keeps management files outside game_root");

my $old_watchdog = $fresh->{watchdog_content};
($ok) = $fresh->start(command => "beta", env => "A=2", run_dir => "bin");
assert_ok($ok && $fresh->{watchdog_content} ne $old_watchdog, "changed options regenerate watchdog content");

my $stale = FakeLifecycle->new;
$stale->{screen} = 1;
my $stale_pid = $stale->spawn("stale-game", 1);
$stale->write("$stale->{management_home}/game.pid", $stale_pid);
($ok) = $stale->start(command => "clean-stale");
assert_ok($ok && !$stale->alive($stale_pid) && $stale->{screen}, "Start preflight clears stale screen and PID trees");

my $rogue = FakeLifecycle->new;
my $tcp = $rogue->spawn("safe-tcp-owner", 1);
my $udp = $rogue->spawn("safe-udp-owner", 1);
$rogue->{tcp}->{27015} = $tcp;
$rogue->{udp}->{27015} = $udp;
($ok) = $rogue->start(command => "clean-ports");
assert_ok($ok && !$rogue->alive($tcp) && !$rogue->alive($udp), "Start preflight clears safe rogue TCP and UDP owners");

my $protected = FakeLifecycle->new;
my $protected_pid = $protected->spawn("protected-port-owner", 0);
$protected->{tcp}->{27015} = $protected_pid;
$protected->{protected}->{$protected_pid} = 1;
($ok, $status) = $protected->start(command => "blocked");
assert_ok(!$ok && $status eq "protected_port_owner" && $protected->alive($protected_pid), "protected process owner refusal preserves process");

my $bot = FakeLifecycle->new;
($ok) = $bot->start(command => "with-bot", bot => 1);
my $game_before = $bot->{files}->{"$bot->{management_home}/game.pid"};
my $bot_before = $bot->{files}->{"$bot->{management_home}/bot.pid"};
$bot->kill_group($bot_before);
$bot->watchdog_tick;
assert_ok($bot->alive($game_before) && $bot->{files}->{"$bot->{management_home}/bot.pid"} != $bot_before, "optional bot restarts independently");

my $late = FakeLifecycle->new;
($ok) = $late->start(command => "late-restart");
my $late_game = $late->{files}->{"$late->{management_home}/game.pid"};
$late->{now} += 121;
$late->kill_group($late_game);
$late->watchdog_tick;
assert_ok($late->status_running && $late->{files}->{"$late->{management_home}/game.pid"} != $late_game, "game restarts after more than 120 seconds");

my $loop = FakeLifecycle->new;
($ok) = $loop->start(command => "crash-loop", bot => 1);
my $loop_game = $loop->{files}->{"$loop->{management_home}/game.pid"};
$loop->{now} += 30;
$loop->kill_group($loop_game);
$loop->watchdog_tick;
assert_ok(!$loop->status_running && !$loop->{screen}, "crash loop under 120 seconds stops and cleans lifecycle");

my $stop_cycle = FakeLifecycle->new;
($ok) = $stop_cycle->start(command => "stop-cycle");
($ok) = $stop_cycle->stop;
$stop_cycle->watchdog_tick;
assert_ok($ok && !$stop_cycle->status_running && !$stop_cycle->{screen}, "Stop during watchdog cycle prevents relaunch");

my $force = FakeLifecycle->new;
($ok) = $force->start(command => "force-stop");
($ok) = $force->force_stop;
assert_ok($ok && !$force->{screen} && scalar(grep { $force->alive($_) } keys %{$force->{pids}}) == 0, "Force Stop leaves screen and process groups inactive");

my $restart = FakeLifecycle->new;
($ok) = $restart->start(command => "old");
($ok) = $restart->restart(command => "new");
assert_ok($ok && $restart->status_running && $restart->{watchdog_content} =~ /new/, "Restart is verified Stop followed by fresh Start");

my $markers = FakeLifecycle->new;
assert_ok(!$markers->status_running, "missing status marker fails safe as stopped");
$markers->write("$markers->{management_home}/status.running", "1,running");
$markers->write("$markers->{management_home}/status.stopped", "1,stopped");
assert_ok(!$markers->status_running, "conflicting status markers fail safe as stopped");

my $manual = FakeLifecycle->new;
($ok) = $manual->start(command => "manual-screen");
$manual->{screen} = 0;
($ok) = $manual->stop;
assert_ok($ok && !$manual->{screen}, "manual screen termination still verifies stopped");

my $replay = FakeLifecycle->new;
$replay->set_state("stopped");
($ok, $status) = $replay->startup_replay;
assert_ok(!$ok && $status eq "desired_stopped", "agent restart while stopped does not auto-start");

my $group = FakeLifecycle->new;
($ok) = $group->start(command => "group-clean");
my $parent = $group->{files}->{"$group->{management_home}/game.pid"};
my $child = $group->spawn("game-child", 1);
$group->{pids}->{$child}->{group} = $group->{pids}->{$parent}->{group};
($ok) = $group->stop;
assert_ok($ok && !$group->alive($parent) && !$group->alive($child), "process-group cleanup kills managed children");

print "Injected lifecycle adapter contract validation passed.\n";
PERL

require_text 'sub validate_game_key_without_decrypt'
require_text 'sub resolve_game_root_without_decrypt'
require_text 'sub resolve_game_payload_path_without_decrypt'
require_text 'return -17;'
require_text 'my ($game_root_ok, $game_root, $game_root_error) = resolve_game_root_without_decrypt($home_path, $game_key);'
require_text 'my ($payload_path_ok, $game_binary_dir, $payload_path_error) = resolve_game_payload_path_without_decrypt($home_path, $game_key, $run_dir);'
require_text 'my ($desired_state, $desired_state_reason) = read_desired_state_without_decrypt($home_path);'
require_text 'Skipping automatic startup for HOME ID:$home_id because desired state is $desired_state ($desired_state_reason).'
require_text 'prepare_server_content_runtime_without_decrypt($home_path);'
require_text 'create_screen_cmd_loop($screen_id, $command, $envVars, undef, undef, $home_path, $game_binary_dir);'
require_text 'backup_home_log( $home_id, $log_file, $game_root . "/" . $console_log );'
require_text '$startup_cmd = replace_Env_Vars($screen_id, $home_id, $game_root, $startup_cmd, $game_key);'
require_text '$line = replace_Env_Vars("", $home_id, $game_root, $line, $game_key);'
require_text 'run_before_start_commands($home_id, $home_path, $preStart, $owner);'
require_text 'my $server_start_bashfile = "$home_path/serverStart.sh";'
require_text 'return ("$home_path/status.running", "$home_path/status.stopped");'
require_text 'foreach my $name ("watchdog.pid", "bot.pid", "game.pid", "game.launch_ts")'
require_text 'my $secure = "$management_scripts_path/secure.sh";'
require_text 'create_secure_script($home_path, $exec_folder_path, $exec_path, $bash_scripts_path);'
require_text 'my $postcmdfile = Path::Class::File->new(MANUAL_TMP_DIR, "postinstall.$$.".time().".sh");'
require_text 'my $secure = "$bash_scripts_path/secure.sh";'
require_absent_text 'my $secure = "$mods_full_path/secure.sh";'
require_absent_text 'my $postcmdfile = $destination."/".'\''postinstall.sh'\'';'

require_order 'resolve_game_root_without_decrypt($home_path, $game_key);' 'hard_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path, remove_startup => 0, preflight => 1);'
require_order 'resolve_game_payload_path_without_decrypt($home_path, $game_key, $run_dir);' 'secure_path_without_decrypt('\''chattr-i'\'', $server_exe);'
require_order 'prepare_server_content_runtime_without_decrypt($home_path);' 'write_desired_state_without_decrypt($home_path, "running")'
require_order 'my ($desired_state, $desired_state_reason) = read_desired_state_without_decrypt($home_path);' 'universal_start_without_decrypt('

echo "Linux lifecycle game-key path contract validation passed."
