package GameManagerLinux;
# Linux process and port checks for GameManager, the counterpart of GameManagerWin.pm.
# Each game runs as its own user (gamehome<id>), so reading its /proc entries, finding who
# holds a port and killing a process need root. They go through the runner the agent sets
# (set_runner), which uses the agent's sudo password. One root call reads the whole process
# list, and every server checked in the same pass shares it, like GameManagerWin's process_table.
use strict;
use warnings;

our $RUNNER;       # sub ($shell_command, $user) -> ($stdout, '') or (undef, $reason)
our $HELPER;       # full path of gm_proc_table.pl
our $TABLE_TTL = 3;

sub set_runner { $RUNNER = $_[0]; return 1; }
sub set_helper { $HELPER = $_[0]; return 1; }

# Runs a shell command as root (or as $user). Returns ($stdout, '') or (undef, $reason).
sub run_as {
	my ($command, $user) = @_;
	return (undef, 'no runner set') unless $RUNNER;
	return $RUNNER->($command, $user // 'root');
}

# Runs a shell command and returns ($stdout, $exit_code). The code is printed by the command
# itself: inside the agent's RPC processes child signals are ignored, so Perl's $? reads -1.
sub qx_rc {
	my ($cmd) = @_;
	my $out = `$cmd; printf '\\nGSE_RC=%s\\n' "\$?"`;
	return (undef, -1) unless defined $out && $out =~ s/\nGSE_RC=(\d+)\n\z//;
	return ($out, $1);
}

# Single-quoted shell word.
sub sh_quote {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/'/'\\''/g;
	return "'$text'";
}

# Pure parser (tested without root). gm_proc_table.pl prints "GSE-PROC 1", then one line per
# process: pid, parent pid, short name, executable, working folder, command line (tab separated).
# Returns an arrayref of { ProcessId, ParentProcessId, Name, ExecutablePath, Cwd, CommandLine },
# or undef when the text is not that list (unknown, never "no processes").
sub parse_proc_table {
	my ($text) = @_;
	return undef unless defined $text && $text =~ /\AGSE-PROC 1\n/;
	my @rows;
	for my $line (split /\n/, $text) {
		my ($pid, $ppid, $name, $exe, $cwd, $cmd) = split /\t/, $line, 6;
		next unless defined $ppid && $pid =~ /^\d+$/ && $ppid =~ /^\d+$/;
		push @rows, { ProcessId => $pid, ParentProcessId => $ppid, Name => $name // '',
			ExecutablePath => $exe // '', Cwd => $cwd // '', CommandLine => $cmd // '' };
	}
	return \@rows;
}

# The process list, read with one root call and kept for a few seconds. Launching or killing a
# process drops it. Returns an arrayref, or undef when it could not be read.
our ($PROCESS_TABLE, $PROCESS_TABLE_AT);
sub forget_process_table { $PROCESS_TABLE = undef; return 1; }
sub process_table {
	return $PROCESS_TABLE if $PROCESS_TABLE && time() - $PROCESS_TABLE_AT < $TABLE_TTL;
	return undef unless $HELPER;
	my ($out) = run_as('perl ' . sh_quote($HELPER));
	my $rows = parse_proc_table($out);
	return undef unless $rows;
	($PROCESS_TABLE, $PROCESS_TABLE_AT) = ($rows, time());
	return $rows;
}

sub _row {
	my ($pid) = @_;
	my $table = process_table() or return undef;
	for my $row (@$table) { return $row if $row->{ProcessId} == $pid; }
	return {};
}

sub _base { my ($p) = @_; $p = '' unless defined $p; $p =~ s{.*/}{}; return $p; }

# Programs that run a game file instead of being the game (java -jar, wine game.exe, ...).
# For those the folder a process "runs from" is its working folder, not the program's own folder.
our @RUNTIME_DIRS = qw(/usr/ /bin/ /sbin/ /lib/ /lib64/ /opt/);
sub _is_runtime { my ($exe) = @_; return scalar grep { index($exe, $_) == 0 } @RUNTIME_DIRS; }

# Pure (tested without root): the path GameManager compares with server folders. The executable
# for a game binary; for a system program (java, wine, mono) the working folder plus its name.
sub row_path {
	my ($row) = @_;
	return undef unless $row && defined $row->{ExecutablePath} && length $row->{ExecutablePath};
	my $exe = $row->{ExecutablePath};
	return $exe unless _is_runtime($exe) && length($row->{Cwd} // '');
	return "$row->{Cwd}/" . _base($exe);
}

# Live checks.
sub pid_alive {
	my ($pid) = @_;
	return 0 unless $pid && $pid =~ /^\d+$/ && -d "/proc/$pid";
	open(my $fh, '<', "/proc/$pid/stat") or return 0;
	my $stat = <$fh>;
	close $fh;
	return (defined $stat && $stat =~ /\) Z /) ? 0 : 1;   # a zombie is not running
}

# Does this PID belong to the expected executable (full path or plain name such as "screen")?
# Returns 1 or 0, or undef when the process list could not be read.
sub pid_executable_matches {
	my ($pid, $expected) = @_;
	return 0 unless $pid && $pid =~ /^\d+$/ && defined $expected && length $expected;
	my $row = _row($pid);
	return undef unless defined $row;
	return 0 unless %$row;
	return row_matches($row, $expected);
}

# Pure: the process is the expected program, by its executable or by the first word it was started with.
sub row_matches {
	my ($row, $expected) = @_;
	my $want = _base($expected);
	return 0 if $want eq '';
	return 1 if _base($row->{ExecutablePath}) eq $want;
	my ($argv0) = split / /, ($row->{CommandLine} // ''), 2;
	return _base($argv0) eq $want ? 1 : 0;
}

sub pid_exe_path {
	my ($pid) = @_;
	my $row = _row($pid);
	return undef unless $row && %$row;
	return row_path($row);
}

# Pure: PIDs of the expected program that run from inside dir (a home's gamefiles folder).
sub pids_in_dir {
	my ($rows, $expected, $dir) = @_;
	return [] unless defined $dir && length $dir;
	(my $d = $dir) =~ s{/+$}{};
	my @found;
	for my $row (@$rows) {
		next unless row_matches($row, $expected);
		my $path = row_path($row) // '';
		push @found, $row->{ProcessId} if index($path, "$d/") == 0;
	}
	return \@found;
}

# All live copies of the game from its folder (arrayref), or undef when the list could not be read.
sub find_all_pids_in_dir {
	my ($expected, $dir) = @_;
	my $table = process_table() or return undef;
	return pids_in_dir($table, $expected, $dir);
}

sub find_pid_in_dir {
	my ($expected, $dir) = @_;
	my $all = find_all_pids_in_dir($expected, $dir);
	return undef unless $all;
	return @$all ? $all->[0] : 0;
}

# Pure: every child, grandchild and so on of root_pid, nearest first.
sub parse_descendants {
	my ($rows, $root) = @_;
	my %kids;
	push @{ $kids{$_->{ParentProcessId}} }, $_->{ProcessId} for @$rows;
	my (@out, %seen);
	my @queue = ($root);
	while (@queue) {
		my $pid = shift @queue;
		for my $kid (@{ $kids{$pid} || [] }) {
			next if $seen{$kid}++;
			push @out, $kid;
			push @queue, $kid;
		}
	}
	return @out;
}

sub child_pids {
	my ($pid) = @_;
	my $table = process_table() or return ();
	return parse_descendants($table, $pid);
}

# Pure: PIDs holding a port, from "ss -Htulnp" output (TCP LISTEN and UDP rows).
sub parse_ss_owners {
	my ($text, $port) = @_;
	return () unless defined $text && defined $port && $port =~ /^\d+$/;
	my %pids;
	for my $line (split /\n/, $text) {
		my @f = split ' ', $line;
		next unless @f >= 5 && $f[0] =~ /^(tcp|udp)$/;
		next if $f[0] eq 'tcp' && $f[1] ne 'LISTEN';
		next unless $f[4] =~ /:(\d+)$/ && $1 == $port;
		$pids{$1} = 1 while $line =~ /pid=(\d+)/g;
	}
	return sort { $a <=> $b } keys %pids;
}

# Pure: is anything on this port, from "ss -Htuln" output.
sub parse_ss_listening {
	my ($text, $port) = @_;
	return 0 unless defined $text && defined $port && $port =~ /^\d+$/;
	for my $line (split /\n/, $text) {
		my @f = split ' ', $line;
		next unless @f >= 5 && $f[0] =~ /^(tcp|udp)$/;
		next if $f[0] eq 'tcp' && $f[1] ne 'LISTEN';
		return 1 if $f[4] =~ /:(\d+)$/ && $1 == $port;
	}
	return 0;
}

sub port_owner_pids {
	my ($port) = @_;
	return () unless $port && $port =~ /^\d+$/;
	my ($out) = run_as('ss -Htulnp');
	return parse_ss_owners($out, $port);
}

# 1 or 0, or undef when ss could not run (unknown, not "free"). No root needed.
sub port_listening {
	my ($port) = @_;
	return 0 unless $port && $port =~ /^\d+$/;
	my ($out, $rc) = qx_rc('ss -Htuln 2>/dev/null');
	return undef if $rc != 0;
	return parse_ss_listening($out, $port);
}

# Kills a process and its whole tree, as the Windows agent does.
sub kill_pid {
	my ($pid) = @_;
	return 0 unless $pid && $pid =~ /^\d+$/ && $pid > 1;
	# Never the agent itself (the scheduler child runs this, its parent is the agent).
	my %agent = map { $_ => 1 } ($$, getppid());
	return 0 if $agent{$pid};
	forget_process_table();
	my @tree = grep { !$agent{$_} } ($pid, child_pids($pid));
	my ($out, $err) = run_as('kill -KILL ' . join(' ', @tree) . ' 2>/dev/null; true');
	forget_process_table();
	return $err ? 0 : 1;
}

sub executable_exists {
	my ($path) = @_;
	return 0 unless defined $path && length $path;
	return -e $path ? 1 : 0 if $path =~ m{^/};
	my (undef, $rc) = qx_rc('command -v ' . sh_quote($path) . ' >/dev/null 2>&1');
	return $rc == 0 ? 1 : 0;
}

# Starts a script inside a detached screen session, as the server's user, from the agent folder
# (screen_config writes the console log to screenlogs/screenlog.<title> there).
# su gives the game its own login session, so it keeps running when the agent stops or restarts.
# Returns ($pid, '') with the screen PID (the launcher), or (0, $reason).
sub launch_screen {
	my (%a) = @_;
	return (0, 'launch failed: no script') unless $a{script};
	my $cmd = 'cd ' . sh_quote($a{run_dir}) . ' && screen -wipe >/dev/null 2>&1;'
		. ' setsid screen -D -m -t ' . sh_quote($a{screen_id}) . ' -c ' . sh_quote($a{screenrc})
		. ' -S ' . sh_quote($a{screen_id}) . ' bash ' . sh_quote($a{script})
		. ' </dev/null >/dev/null 2>&1 & echo $!';
	my ($out, $err) = run_as($cmd, $a{user});
	forget_process_table();
	return (0, "launch failed: $err") if $err;
	my ($pid) = ($out // '') =~ /(\d+)\s*\z/;
	return (0, 'launch failed: no process id') unless $pid;
	return ($pid, '');
}

# serverStart.sh in the server folder: the Linux form of serverStart.bat. It records the start
# and the exit code in last-start.txt, loads gse_prestart.sh (environment and the game config's
# pre-start commands, written at Start), then runs the game. No exec: the game stays a child of
# this bash, so the launched tree can be stopped as one.
sub write_server_script {
	my ($gm, $h, $dir) = @_;
	my $wd = $h->{workdir} // "$dir/gamefiles";
	my $root = "$dir/gamefiles";
	open(my $fh, '>', "$dir/serverStart.sh") or return 0;
	my $q = \&sh_quote;
	print $fh "#!/bin/bash\n"
		. "# Game server $h->{id}. The agent runs this in screen and starts it again while RUNNING is wanted.\n"
		. "echo \"\$(date '+%Y-%m-%d %H:%M:%S') start\" > " . $q->("$dir/last-start.txt") . "\n"
		. "cd " . $q->($root) . " || exit 1\n"
		. "GSE_LAUNCH_PREFIX=''\n"
		. "[ -r " . $q->("$dir/gse_prestart.sh") . " ] && . " . $q->("$dir/gse_prestart.sh") . "\n"
		. "cd " . $q->($wd) . " || exit 1\n"
		. "\$GSE_LAUNCH_PREFIX $h->{command}\n"
		. "code=\$?\n"
		. "echo \"\$(date '+%Y-%m-%d %H:%M:%S') exit \$code\" >> " . $q->("$dir/last-start.txt") . "\n";
	close $fh;
	chmod 0755, "$dir/serverStart.sh";
	return 1;
}

# startserver.sh and stopserver.sh in the server folder, for an admin working on the host. Like
# the .bat files on Windows they only record RUNNING or STOPPED; the agent's check does the work.
sub write_admin_script {
	my ($gm, $id, $dir, $action) = @_;
	my $ctl = "$gm->{agent_dir}/gse_ctl.pl";
	open(my $fh, '>', "$dir/${action}server.sh") or return 0;
	print $fh "#!/bin/bash\n# $action game server $id, like the panel button. The agent does the work within 30 seconds.\n"
		. "exec perl " . sh_quote($ctl) . " $action $id " . sh_quote($dir) . "\n";
	close $fh;
	chmod 0755, "$dir/${action}server.sh";
	return 1;
}

# The bot is _alsoRun.sh in the server folder (the Linux form of _alsoRun.cmd): a normal script
# that changes into the bot's folder itself. It is run through bash, so it is one process tree.
sub read_bot_config {
	my ($file) = @_;
	return undef unless defined $file && -e $file;
	(my $dir = $file) =~ s{/[^/]+$}{};
	return { script => $file, workdir => $dir, executable => '/bin/bash', arguments => $file,
		command => "/bin/bash $file" };
}

1;
