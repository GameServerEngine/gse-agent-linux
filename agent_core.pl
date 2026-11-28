#!/usr/bin/perl
#
# Gameserver Engine Linux Agent
# Copyright (C) 2008 - 2018 The GSP Development Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

use warnings;
use strict;

use Cwd;			 # Fast way to get the current directory
use lib getcwd();
use Frontier::Daemon::GSP::Forking;	# Forking XML-RPC server
use File::Copy;				   # Simple file copy functions
use File::Copy::Recursive
  qw(fcopy rcopy dircopy fmove rmove dirmove pathempty pathrmdir)
  ;							   # Used to copy whole directories
use File::Basename; # Used to get the file name or the directory name from a given path
use Crypt::XXTEA;	# Encryption between webpages and agent.
use Cfg::Config;	 # Config file
use Cfg::Preferences;   # Preferences file
use Fcntl qw(:flock O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);  # LOCK_* for file locking, O_* for symlink-safe log files
use LWP::UserAgent; # Used for fetching URLs
use MIME::Base64;	# Used to ensure data travelling right through the network.
use Getopt::Long;	# Used for command line params.
use Path::Class::File;	# Used to handle files and directories.
use File::Glob qw(bsd_glob GLOB_NOSORT);
use File::Path qw(mkpath);
use Archive::Extract;	 # Used to handle archived files.
use File::Find;
use File::Spec;
use Schedule::Cron; # Used for scheduling tasks
use JSON::PP;
use IO::Socket::INET;
use POSIX ();
use Digest::SHA qw(hmac_sha256_hex);
use Sys::Hostname qw(hostname);
use GameManager;        # start, stop and monitor rules, shared with the Windows agent
use GameManagerLinux;   # Linux process and port checks for GameManager
use GSE::Container::Runtime; # opt-in Docker container boundary, shared with the Windows agent
use GSE::Resource::Inventory qw(collect_linux_inventory); # read-only hardware inventory (Phase 2)

# Compression tools
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error); # Used to compress files to bz2.
use Compress::Zlib; # Used to compress file download buffers to zlib.
use Archive::Tar; # Used to create tar, tgz or tbz archives.
use Archive::Zip qw( :ERROR_CODES :CONSTANTS ); # Used to create zip archives.

# Current location of the agent.
use constant AGENT_RUN_DIR => getcwd();

# Load our config file values
use constant AGENT_KEY	  => $Cfg::Config{key};
use constant AGENT_IP	   => $Cfg::Config{listen_ip};
use constant AGENT_LOG_FILE => $Cfg::Config{logfile};
use constant AGENT_PORT	 => $Cfg::Config{listen_port};
use constant AGENT_CODE_VERSION => 'gse-linux-agent-1.8.5';
use constant AGENT_VERSION  => AGENT_CODE_VERSION;
use constant AGENT_PROTOCOL_VERSION => 1;
use constant WEB_ADMIN_API_KEY  => $Cfg::Config{web_admin_api_key};
use constant WEB_API_URL => $Cfg::Config{web_api_url};
use constant STEAM_DL_LIMIT => $Cfg::Config{steam_dl_limit};
# Resource stats database configuration
use constant STATS_DB_HOST => $Cfg::Config{stats_db_host};
use constant STATS_DB_USER => $Cfg::Config{stats_db_user};
use constant STATS_DB_PASS => $Cfg::Config{stats_db_pass};
use constant STATS_DB_NAME => $Cfg::Config{stats_db_name};
use constant STATS_TABLE_PREFIX => $Cfg::Config{stats_table_prefix};
use constant STATS_FREQUENCY_MINUTES => $Cfg::Config{stats_frequency_minutes};
use constant SCREEN_LOG_LOCAL  => $Cfg::Preferences{screen_log_local};
use constant DELETE_LOGS_AFTER  => $Cfg::Preferences{delete_logs_after};
use constant PORT_VALIDATION_ENABLED =>
  defined($Cfg::Preferences{PortValidationEnabled}) ? $Cfg::Preferences{PortValidationEnabled} : 1;
use constant STARTUP_VALIDATION_TIMEOUT =>
  defined($Cfg::Preferences{StartupValidationTimeoutSeconds}) ? $Cfg::Preferences{StartupValidationTimeoutSeconds} : 180;
use constant PORT_CHECK_INTERVAL_SECONDS =>
  defined($Cfg::Preferences{PortCheckIntervalSeconds}) ? $Cfg::Preferences{PortCheckIntervalSeconds} : 5;
use constant LINUX_USER_PER_GAME_SERVER  => $Cfg::Preferences{linux_user_per_game_server};
use constant CONTAINER_RUNTIME_ENABLED =>
  defined($Cfg::Preferences{container_runtime_enabled}) && $Cfg::Preferences{container_runtime_enabled} eq "1" ? 1 : 0;
use constant CONTAINER_RUNTIME =>
  defined($Cfg::Preferences{container_runtime}) && $Cfg::Preferences{container_runtime} ne "" ? $Cfg::Preferences{container_runtime} : "docker";
use constant CONTAINER_RUNTIME_DOCKER_BINARY =>
  defined($Cfg::Preferences{container_runtime_docker_binary}) && $Cfg::Preferences{container_runtime_docker_binary} ne "" ? $Cfg::Preferences{container_runtime_docker_binary} : "docker";
use constant CONTAINER_DATA_ROOT =>
  defined($Cfg::Preferences{container_data_root}) && $Cfg::Preferences{container_data_root} ne "" ? $Cfg::Preferences{container_data_root} : File::Spec->catdir(AGENT_RUN_DIR, "containers");
# Images containers may use, as reference prefixes (e.g. "eclipse-temurin:21-jre"). Empty means none.
use constant CONTAINER_ALLOWED_IMAGES =>
  defined($Cfg::Preferences{container_allowed_images}) ? $Cfg::Preferences{container_allowed_images} : "";
use constant CONTAINER_NETWORK =>
  defined($Cfg::Preferences{container_network}) && $Cfg::Preferences{container_network} =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/ ? $Cfg::Preferences{container_network} : "gse-games";
use constant CONTAINER_GAME_MOUNT => "/game";
use constant CONTAINER_CONTROL_MOUNT => "/run/gse";
use constant AGENT_PID_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'agent_core.pid');
use constant AGENT_RSYNC_GENERIC_LOG =>
  Path::Class::File->new(AGENT_RUN_DIR, 'rsync_update_generic.log');
use constant STEAM_LICENSE_OK => "Accept";
use constant STEAM_LICENSE	=> $Cfg::Config{steam_license};
use constant MANUAL_TMP_DIR   => Path::Class::Dir->new(AGENT_RUN_DIR, 'tmp');
use constant SHARED_GAME_TMP_DIR   => Path::Class::Dir->new(AGENT_RUN_DIR, 'shared');
use constant STEAMCMD_CLIENT_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'steamcmd');
use constant STEAMCMD_CLIENT_BIN =>
  Path::Class::File->new(STEAMCMD_CLIENT_DIR, 'steamcmd.sh');
use constant SCREEN_LOGS_DIR =>
  Path::Class::Dir->new(AGENT_RUN_DIR, 'screenlogs');
use constant GAME_STARTUP_DIR =>
  Path::Class::Dir->new(AGENT_RUN_DIR, 'startups');
use constant SERVER_RUNTIME_DIR =>
	Path::Class::Dir->new(AGENT_RUN_DIR, 'runtime_status');
use constant AGENT_EVENTS_DIR =>
	Path::Class::Dir->new(AGENT_RUN_DIR, 'events');
use constant AGENT_EVENT_QUEUE_FILE =>
	Path::Class::File->new(AGENT_EVENTS_DIR, 'pending-events.jsonl');
use constant AGENT_UPDATE_STATE_FILE =>
	Path::Class::File->new(AGENT_RUN_DIR, 'agent_core_update_state.json');
use constant AGENT_UPDATE_REQUEST_FILE =>
	Path::Class::File->new(AGENT_RUN_DIR, 'agent_core_update_request.json');
use constant AGENT_UPDATE_LOG_FILE =>
	Path::Class::File->new(AGENT_RUN_DIR, 'agent_core_update.log');
use constant SCREENRC_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'screen_config');
use constant SCREENRC_FILE_BK =>
  Path::Class::File->new(AGENT_RUN_DIR, 'screen_config_bk');
use constant SCREENRC_TMP_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'screen_config.tmp');
use constant SCREEN_TYPE_HOME   => "HOME";
use constant SCREEN_TYPE_UPDATE => "UPDATE";
use constant SERVER_RUNNER_USER => "server_runner";
use constant FD_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'FastDownload');
use constant FD_ALIASES_DIR => Path::Class::Dir->new(FD_DIR, 'aliases');
use constant FD_PID_FILE => Path::Class::File->new(FD_DIR, 'fd.pid');
use constant SCHED_PID => Path::Class::File->new(AGENT_RUN_DIR, 'Schedule', 'scheduler.pid');
use constant SCHED_TASKS => Path::Class::File->new(AGENT_RUN_DIR, 'Schedule', 'scheduler.tasks');
use constant SCHED_LOG_FILE => Path::Class::File->new(AGENT_RUN_DIR, 'Schedule', 'scheduler.log');

$Cfg::Config{sudo_password} =~ s/('+)/'\"$1\"'/g;
our $SUDOPASSWD = $Cfg::Config{sudo_password};
my $no_startups	= 0;
my $clear_startups = 0;
our $log_std_out = 0;
my $agent_pid_file = AGENT_PID_FILE;

GetOptions(
		   'no-startups'	=> \$no_startups,
		   'clear-startups' => \$clear_startups,
		   'log-stdout'	 => \$log_std_out,
		   'pidfile=s'	 => \$agent_pid_file
		  );

sub preference_value
{
	my ($primary, $legacy, $default) = @_;
	return $Cfg::Preferences{$primary} if(defined($Cfg::Preferences{$primary}));
	return $Cfg::Preferences{$legacy} if(defined($legacy) && defined($Cfg::Preferences{$legacy}));
	return $default;
}

sub preference_enabled
{
	my ($primary, $legacy, $default) = @_;
	my $value = preference_value($primary, $legacy, $default);
	return defined($value) && $value eq "1" ? 1 : 0;
}

# Starting the agent as root user is not supported anymore.
if ($< == 0)
{
	print "ERROR: You are trying to start the agent as root user.";
	print "This is not currently supported. If you wish to start the";
	print "you need to create a normal user account for it.";
	exit 1;
}

### Logger function.
### @param line the line that is put to the log file.
sub logger
{
	my $logcmd	 = $_[0];
	my $also_print = 0;

	if (@_ == 2)
	{
		($also_print) = $_[1];
	}

	$logcmd = localtime() . " $logcmd\n";

	if ($log_std_out == 1)
	{
		print "$logcmd";
		return;
	}
	if ($also_print == 1)
	{
		print "$logcmd";
	}

	open(LOGFILE, '>>', AGENT_LOG_FILE)
	  or die("Can't open " . AGENT_LOG_FILE . " - $!");
	flock(LOGFILE, LOCK_EX) or die("Failed to lock log file.");
	seek(LOGFILE, 0, 2) or die("Failed to seek to end of file.");
	print LOGFILE "$logcmd" or die("Failed to write to log file.");
	flock(LOGFILE, LOCK_UN) or die("Failed to unlock log file.");
	close(LOGFILE) or die("Failed to close log file.");
}

sub agent_event_panel_url
{
	return $Cfg::Config{agent_event_url} if(defined($Cfg::Config{agent_event_url}) && $Cfg::Config{agent_event_url} ne "");
	if(defined($Cfg::Config{web_api_url}) && $Cfg::Config{web_api_url} ne "")
	{
		my $url = $Cfg::Config{web_api_url};
		$url =~ s/api\.php(?:\?.*)?$/agent_event_receiver.php/;
		return $url if($url =~ /agent_event_receiver\.php$/);
		$url =~ s/\/+$//;
		return "$url/agent_event_receiver.php";
	}
	return "";
}

sub agent_event_remote_server_id
{
	return $Cfg::Config{remote_server_id} if(defined($Cfg::Config{remote_server_id}) && $Cfg::Config{remote_server_id} =~ /^\d+$/);
	return $Cfg::Config{agent_remote_server_id} if(defined($Cfg::Config{agent_remote_server_id}) && $Cfg::Config{agent_remote_server_id} =~ /^\d+$/);
	return "";
}

sub prepare_server_content_runtime_without_decrypt
{
	my ($home_path) = @_;
	return if(!defined($home_path) || $home_path eq "");
	foreach my $dir (
		game_content_dir($home_path) . "",
		game_content_dir($home_path) . "/hooks",
		game_content_dir($home_path) . "/generated",
		game_content_dir($home_path) . "/runtime"
	)
	{
		mkpath($dir) if(!-d $dir);
	}
	my $pid_file = game_content_dir($home_path) . "/runtime/server_content.pids";
	if(!-e $pid_file && open(my $fh, '>', $pid_file))
	{
		close($fh);
	}
}

sub append_server_content_pid_without_decrypt
{
	my ($pid_file, $pid, $role, $label) = @_;
	return unless(defined($pid_file) && $pid_file ne "" && defined($pid) && $pid =~ /^\d+$/);
	$role = "app" unless(defined($role) && $role =~ /^(watchdog|app|main_server)$/i);
	$label = "" unless(defined($label));
	if(open(my $fh, '>>', $pid_file))
	{
		print $fh "$role $pid $label\n";
		close($fh);
	}
}

sub import_legacy_also_run_pids_without_decrypt
{
	my ($home_path) = @_;
	return if(!defined($home_path) || $home_path eq "");
	prepare_server_content_runtime_without_decrypt($home_path);
	my $pid_file = game_content_dir($home_path) . "/runtime/server_content.pids";
	my %seen;
	foreach my $legacy_pid_file ("$home_path/_alsoRun.pid", bsd_glob("$home_path/*/_alsoRun.pid"))
	{
		next if(!defined($legacy_pid_file) || $legacy_pid_file eq "" || !-f $legacy_pid_file);
		if(open(my $in, '<', $legacy_pid_file))
		{
			while(my $line = <$in>)
			{
				chomp($line);
				my ($pid) = $line =~ /(\d{2,})/;
				next unless(defined($pid) && !$seen{$pid});
				$seen{$pid} = 1;
				append_server_content_pid_without_decrypt($pid_file, $pid, "app", "legacy_alsoRun");
			}
			close($in);
		}
	}
}

sub cleanup_server_content_pid_group_without_decrypt
{
	my ($pid_file, $wanted_role, $as_user) = @_;
	return if(!-f $pid_file);
	my @remaining;
	my %killed;
	my $in;
	if(!open($in, '<', $pid_file))
	{
		logger "Could not read server content PID file $pid_file: $!";
		return;
	}
	while(my $line = <$in>)
	{
		chomp($line);
		my $original = $line;
		$line =~ s/^\s+|\s+$//g;
		next if($line eq "");
		my ($pid) = $line =~ /(?:^|[^\d])(\d{2,})(?:[^\d]|$)/;
		my $role = ($line =~ /watchdog/i) ? "watchdog" : "app";
		$role = "main_server" if($line =~ /main[_-]?server/i);
		if(defined($pid) && $role eq $wanted_role)
		{
			next if($killed{$pid});
			$killed{$pid} = 1;
			logger "Stopping server-content $role PID $pid from $pid_file.";
			sudo_exec_without_decrypt("kill -TERM $pid >/dev/null 2>&1 || true", $as_user);
			sleep 1 if($wanted_role eq "watchdog");
			sudo_exec_without_decrypt("kill -KILL $pid >/dev/null 2>&1 || true", $as_user);
			next;
		}
		push(@remaining, $original);
	}
	close($in);
	if(open(my $out, '>', $pid_file))
	{
		foreach my $line (@remaining)
		{
			print $out "$line\n";
		}
		close($out);
	}
}

sub cleanup_server_content_hooks_without_decrypt
{
	my ($home_path, $as_user) = @_;
	return if(!defined($home_path) || $home_path eq "");
	import_legacy_also_run_pids_without_decrypt($home_path);
	my $pid_file = game_content_dir($home_path) . "/runtime/server_content.pids";
	cleanup_server_content_pid_group_without_decrypt($pid_file, "watchdog", $as_user);
	cleanup_server_content_pid_group_without_decrypt($pid_file, "app", $as_user);
}

sub new_correlation_id
{
	return time() . "-" . $$ . "-" . int(rand(1000000000));
}

sub new_agent_event_uuid
{
	return "agent-" . new_correlation_id();
}

sub build_agent_event
{
	my ($event_type, $severity, $fields) = @_;
	$fields = {} unless(ref($fields) eq 'HASH');
	my %event = %$fields;
	$event{event_uuid} ||= new_agent_event_uuid();
	$event{timestamp_utc} ||= gmtime() . " UTC";
	$event{event_type} = $event_type;
	$event{severity} = $severity;
	$event{source} = "agent";
	$event{agent_os} ||= "Linux";
	$event{agent_hostname} ||= hostname();
	$event{remote_server_id} ||= agent_event_remote_server_id();
	$event{correlation_id} ||= new_correlation_id();
	foreach my $secret_key (qw(password control_password steam_password encryption_key database_password envVars environment_variables))
	{
		delete $event{$secret_key};
	}
	return \%event;
}

sub agent_event_json
{
	my ($event) = @_;
	return JSON::PP->new->ascii->canonical->encode($event);
}

sub send_agent_event
{
	my ($event) = @_;
	my $url = agent_event_panel_url();
	my $remote_server_id = agent_event_remote_server_id();
	return 0 if($url eq "" || $remote_server_id eq "" || AGENT_KEY eq "");
	my $body = agent_event_json($event);
	my $timestamp = time();
	my $signature = "sha256=" . hmac_sha256_hex($timestamp . "." . $body, AGENT_KEY);
	my $ua = LWP::UserAgent->new(timeout => 5, ssl_opts => { verify_hostname => 0, SSL_verify_mode => 0x00 });
	my $response = $ua->post($url,
		'Content-Type' => 'application/json',
		'X-GSP-Agent-Id' => $remote_server_id,
		'X-GSP-Agent-Timestamp' => $timestamp,
		'X-GSP-Agent-Signature' => $signature,
		Content => $body
	);
	return ($response && $response->is_success) ? 1 : 0;
}

sub append_agent_event_queue
{
	my ($event) = @_;
	mkpath(AGENT_EVENTS_DIR) unless(-d AGENT_EVENTS_DIR);
	if(open(EVENTQ, '>>', AGENT_EVENT_QUEUE_FILE))
	{
		flock(EVENTQ, LOCK_EX);
		print EVENTQ agent_event_json($event) . "\n";
		flock(EVENTQ, LOCK_UN);
		close(EVENTQ);
	}
	if(-e AGENT_EVENT_QUEUE_FILE && -s AGENT_EVENT_QUEUE_FILE > 1048576)
	{
		rename(AGENT_EVENT_QUEUE_FILE, AGENT_EVENT_QUEUE_FILE . "." . time() . ".old");
	}
}

sub flush_agent_event_queue
{
	return 0 unless(-e AGENT_EVENT_QUEUE_FILE);
	open(EVENTQ, '<', AGENT_EVENT_QUEUE_FILE) or return 0;
	my @lines = <EVENTQ>;
	close(EVENTQ);
	my @remaining;
	my $delivered = 0;
	foreach my $line (@lines)
	{
		chomp($line);
		next if($line eq "");
		my $event = eval { JSON::PP->new->decode($line) };
		if($@ || ref($event) ne 'HASH')
		{
			next;
		}
		if(send_agent_event($event))
		{
			$delivered++;
		}
		else
		{
			push(@remaining, $line);
		}
	}
	if(open(EVENTQ, '>', AGENT_EVENT_QUEUE_FILE))
	{
		flock(EVENTQ, LOCK_EX);
		print EVENTQ join("\n", @remaining) . (@remaining ? "\n" : "");
		flock(EVENTQ, LOCK_UN);
		close(EVENTQ);
	}
	return $delivered;
}

sub queue_agent_event
{
	my ($event_type, $severity, $fields) = @_;
	my $event = build_agent_event($event_type, $severity, $fields);
	if(send_agent_event($event))
	{
		flush_agent_event_queue();
		return 1;
	}
	append_agent_event_queue($event);
	return 0;
}

sub agent_event_state_path
{
	my ($home_id) = @_;
	$home_id =~ s/[^0-9]//g;
	return Path::Class::File->new(AGENT_EVENTS_DIR, "state-$home_id.kv");
}

sub read_agent_event_state
{
	my ($home_id) = @_;
	my %state;
	my $file = agent_event_state_path($home_id);
	return \%state unless(-e $file);
	open(STATE, '<', $file) or return \%state;
	while(my $line = <STATE>)
	{
		chomp($line);
		next unless($line =~ /^([^=]+)=(.*)$/);
		$state{$1} = $2;
	}
	close(STATE);
	return \%state;
}

sub write_agent_event_state
{
	my ($home_id, $state) = @_;
	mkpath(AGENT_EVENTS_DIR) unless(-d AGENT_EVENTS_DIR);
	my $file = agent_event_state_path($home_id);
	open(STATE, '>', $file) or return 0;
	foreach my $key (sort keys %$state)
	{
		my $value = defined($state->{$key}) ? $state->{$key} : "";
		$value =~ s/[\r\n]//g;
		print STATE "$key=$value\n";
	}
	close(STATE);
	return 1;
}

sub record_server_state_transition
{
	my ($status_info) = @_;
	return unless(ref($status_info) eq 'HASH');
	my $home_id = $status_info->{home_id};
	return unless(defined($home_id) && $home_id =~ /^\d+$/);
	my $previous = read_agent_event_state($home_id);
	my $current_status = $status_info->{status} || "UNKNOWN";
	my $previous_status = $previous->{status} || "";
	my $now = time();
	my ($event_type, $severity);
	if(($status_info->{restart_reason} || "") eq "automatic_restart" && !($previous->{autorestart_pending} || 0))
	{
		($event_type, $severity) = ("automatic_restart_started", "warning");
		$previous->{autorestart_pending} = 1;
	}
	elsif(($previous->{autorestart_pending} || 0) && $current_status eq "ONLINE")
	{
		($event_type, $severity) = ("automatic_restart_succeeded", "info");
		delete $previous->{autorestart_pending};
	}
	elsif(($previous->{autorestart_pending} || 0) && $current_status eq "UNRESPONSIVE")
	{
		($event_type, $severity) = ("automatic_restart_failed", "error");
		delete $previous->{autorestart_pending};
	}
	elsif($previous_status eq "ONLINE" && $current_status eq "OFFLINE")
	{
		($event_type, $severity) = ("server_crash_detected", "warning");
	}
	elsif($previous_status ne "ONLINE" && $current_status eq "ONLINE")
	{
		($event_type, $severity) = ("server_start_confirmed", "info");
	}
	elsif($current_status eq "UNRESPONSIVE" && $previous_status ne "UNRESPONSIVE")
	{
		($event_type, $severity) = ("server_unresponsive", "warning");
	}
	elsif($current_status eq "WARNING" && $previous_status ne "WARNING")
	{
		$event_type = $status_info->{process_running} ? "server_process_found_without_port" : "server_port_found_without_managed_process";
		$severity = "warning";
	}
	elsif(($previous_status eq "WARNING" || $previous_status eq "UNRESPONSIVE") && $current_status eq "ONLINE")
	{
		($event_type, $severity) = ("server_port_restored", "notice");
	}
	if($event_type)
	{
		my $last_sent = $previous->{"sent_$event_type"} || 0;
		if($previous_status ne $current_status || ($now - $last_sent) > 900)
		{
			queue_agent_event($event_type, $severity, $status_info);
			$previous->{"sent_$event_type"} = $now;
		}
	}
	$previous->{status} = $current_status;
	$previous->{updated_at} = $now;
	write_agent_event_state($home_id, $previous);
}

# Rotate the log file
if (-e AGENT_LOG_FILE)
{
	if (-e AGENT_LOG_FILE . ".bak")
	{
		unlink(AGENT_LOG_FILE . ".bak");
	}
	logger "Rotating log file";
	move(AGENT_LOG_FILE, AGENT_LOG_FILE . ".bak");
	logger "New log file created";
}

# If for some reason the screenrc file doesn't exist, restore it from the backup copy
# I've seen this happen a few times
if (! -e SCREENRC_FILE)
{
	copy(SCREENRC_FILE_BK,SCREENRC_FILE);
}

open INPUTFILE, "<", SCREENRC_FILE or die $!;
open OUTPUTFILE, ">", SCREENRC_TMP_FILE or die $!;
my $dest = SCREEN_LOGS_DIR . "/screenlog.%t";
while (<INPUTFILE>)
{
	$_ =~ s/logfile.*/logfile $dest/g;
	print OUTPUTFILE $_;
}
close INPUTFILE;
close OUTPUTFILE;
unlink SCREENRC_FILE;
move(SCREENRC_TMP_FILE,SCREENRC_FILE);

# Check the screen logs folder
if (!-d SCREEN_LOGS_DIR && !mkdir SCREEN_LOGS_DIR)
{
	logger "Could not create " . SCREEN_LOGS_DIR . " directory $!.", 1;
	exit -1;
}

# Sticky bit: every game user may create its own screen log, but none may delete,
# rename or replace another server's log (which also blocks symlink swaps).
if ( ! chmod 01777, SCREEN_LOGS_DIR ){
	logger "Could not chmod 1777 " . SCREEN_LOGS_DIR . " directory $!.", 1;
	exit -1;
}

my $groupCommandScreenLogs = "chmod -Rf g-s '" . SCREEN_LOGS_DIR . "'";
sudo_exec_without_decrypt($groupCommandScreenLogs);

$groupCommandScreenLogs = "find '" . SCREEN_LOGS_DIR  . "' -type d | xargs chmod g+s";
sudo_exec_without_decrypt($groupCommandScreenLogs);

$groupCommandScreenLogs = "find '" . SCREEN_LOGS_DIR  . "' -type d | xargs setfacl -d -m u::rwX,g::rwX,o::-";
sudo_exec_without_decrypt($groupCommandScreenLogs);

# Check the global shared games folder
if (!-d SHARED_GAME_TMP_DIR && !mkdir SHARED_GAME_TMP_DIR)
{
	logger "Could not create " . SHARED_GAME_TMP_DIR . " directory $!.", 1;
	exit -1;
}

# create the directory for startup flags
if (!-e GAME_STARTUP_DIR)
{
	logger "Creating the startups directory " . GAME_STARTUP_DIR . "";
	if (!mkdir GAME_STARTUP_DIR)
	{
		my $message =
			"Failed to create the "
		  . GAME_STARTUP_DIR
		  . " directory - check permissions. Errno: $!";
		logger $message, 1;
		exit 1;
	}
}

if (!-d SERVER_RUNTIME_DIR && !mkdir SERVER_RUNTIME_DIR)
{
	logger "Could not create " . SERVER_RUNTIME_DIR . " directory $!.", 1;
	exit -1;
}

elsif ($clear_startups)
{
	opendir(STARTUPDIR, GAME_STARTUP_DIR);
	while (my $startup_file = readdir(STARTUPDIR))
	{

		# Skip . and ..
		next if $startup_file =~ /^\./;
		$startup_file = Path::Class::File->new(GAME_STARTUP_DIR, $startup_file);
		logger "Removing " . $startup_file . ".";
		unlink($startup_file);
	}
	closedir(STARTUPDIR);
}
# If the directory already existed check if we need to start some games.
# Servers wanted RUNNING are started (or adopted, if their game is still up) by the game
# monitor's first pass (gm_monitor_all), as on Windows. Startup flags are kept for the
# resource statistics only.

# Create the pid file
open(PID, '>', $agent_pid_file)
  or die("Can't write to pid file - " . $agent_pid_file . "\n");
print PID "$$\n";
close(PID);

logger "Gameserver Engine - Agent started - "
  . AGENT_VERSION
  . " - port "
  . AGENT_PORT
  . " - PID $$", 1;

# Stop previous scheduler process if exists
scheduler_stop();
# Create new object with default dispatcher for scheduled tasks
my $cron = new Schedule::Cron( \&scheduler_dispatcher, {
                                        nofork => 1,
                                        loglevel => 0,
                                        log => sub { print $_[1], "\n"; }
                                       } );

$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
$cron->add_entry( "* * * * * */5", \&gm_monitor_all );   # game monitor, every 5 seconds
# Add resource stats collection task if configured
if (defined STATS_FREQUENCY_MINUTES && STATS_FREQUENCY_MINUTES =~ /^\d+$/ && STATS_FREQUENCY_MINUTES > 0) {
	logger "Scheduling resource stats collection every " . STATS_FREQUENCY_MINUTES . " minutes.";
	logger "Resource stats collection task added with schedule: */" . STATS_FREQUENCY_MINUTES . " * * * *";
	$cron->add_entry( "*/" . STATS_FREQUENCY_MINUTES . " * * * *", \&collect_and_submit_resource_stats );
} else {
	logger "Resource stats collection not configured or invalid frequency: " . (defined STATS_FREQUENCY_MINUTES ? STATS_FREQUENCY_MINUTES : 'undefined');
}

# Create scheduler directory if it doesn't exist
my $sched_dir = Path::Class::Dir->new(AGENT_RUN_DIR, 'Schedule');
if (!-d $sched_dir) {
	if (mkpath($sched_dir)) {
		logger "Created scheduler directory: $sched_dir";
	} else {
		logger "Failed to create scheduler directory: $sched_dir - $!";
	}
}

# Create scheduler tasks file if it doesn't exist to prevent read errors
if (!-e SCHED_TASKS) {
	if (open(TASKS_INIT, '>', SCHED_TASKS)) {
		logger "Created empty scheduler tasks file: " . SCHED_TASKS;
		close(TASKS_INIT);
	} else {
		logger "Failed to create scheduler tasks file: " . SCHED_TASKS . " - $!";
	}
}

# Run scheduler
$cron->run( {detach=>1, pid_file=>SCHED_PID} );

if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
{
	require "FastDownload/Settings.pm"; # Settings for Fast Download Daemon.
	if(defined($FastDownload::Settings{autostart_on_agent_startup}) && $FastDownload::Settings{autostart_on_agent_startup} eq "1")
	{
		start_fastdl();
	}
}

	# ---------------------------------------------------------------------------
	# restic job runner for the panel's self-service backup / restore.
	#
	# Secrets (RESTIC_REPOSITORY, RESTIC_PASSWORD) arrive XXTEA-encrypted like every
	# other RPC parameter and reach restic only through its environment. They never
	# appear in argv, in the job log, or in any file on disk.
	#
	# argv is checked against an allowlist of exact shapes, one per operation the
	# panel needs. Anything else is refused, so restic's own options (repository,
	# password files, commands, cache dirs) cannot be reached through this RPC.
	#
	# A job runs detached from the RPC request, so a panel timeout does not stop it.
	# Its state stays in the job directory until the panel reads it. A job whose
	# supervisor is gone and that has no recorded result is reported as 'lost'.
	# ---------------------------------------------------------------------------
	use constant RESTIC_JOB_ROOT    => ($ENV{RESTIC_JOB_ROOT} || '/var/lib/gse-agent/restic-jobs');
	use constant RESTIC_OUTPUT_TAIL => 65536;
	# Game server folders live under this root: <root>/<digits>. Set GAME_HOME_ROOT for another layout.
	use constant RESTIC_HOME_ROOT   => ($ENV{GAME_HOME_ROOT} || '/home/gameserver');

	my %RESTIC_ENV_KEYS = map { $_ => 1 } qw(RESTIC_REPOSITORY RESTIC_PASSWORD);

	sub restic_job_id_ok
	{
		my ($job_id) = @_;
		return (defined $job_id && $job_id =~ /^[a-f0-9]{32}\z/) ? 1 : 0;
	}

	sub restic_job_slurp
	{
		my ($path) = @_;
		open(my $fh, '<', $path) or return undef;
		local $/;
		my $data = <$fh>;
		close($fh);
		return $data;
	}

	sub restic_job_write_file
	{
		my ($path, $data) = @_;
		open(my $fh, '>', "$path.tmp") or return 0;
		print $fh $data;
		close($fh);
		return rename("$path.tmp", $path) ? 1 : 0;
	}

	# Start time of a live process from /proc, or undef if it is gone or a zombie.
	sub restic_pid_start_time
	{
		my ($pid) = @_;
		my $stat = restic_job_slurp("/proc/$pid/stat");
		return undef unless defined $stat;
		my ($rest) = $stat =~ /^.*\)\s(.*)\z/s;
		return undef unless defined $rest;
		my @fields = split(' ', $rest);
		return undef if (!@fields || $fields[0] eq 'Z');
		return $fields[19];
	}

	sub restic_bin_path
	{
		return $ENV{RESTIC_BIN} if ($ENV{RESTIC_BIN} && -f $ENV{RESTIC_BIN} && -x $ENV{RESTIC_BIN});
		foreach my $candidate ('/usr/local/bin/restic', '/usr/bin/restic')
		{
			return $candidate if (-f $candidate && -x $candidate);
		}
		return undef;
	}

	# Paths restic may touch: a game server folder (<home root>/<digits>) or a path inside one.
	# Same rule as the Windows agent: canonical form only, no '.' or '..' segments.
	sub restic_arg_home_path_ok
	{
		my ($path) = @_;
		return 0 unless (defined $path && length($path) <= 4096);
		my $root = RESTIC_HOME_ROOT;
		return 0 unless ($root =~ m{\A/[^/\x00-\x1f]+(?:/[^/\x00-\x1f]+)*\z} && $root !~ m{(?:\A|/)\.\.?(?:/|\z)});
		return 0 unless ($path =~ m{\A\Q$root\E/[0-9]{1,10}(?:/[^/\x00-\x1f]+)*\z});
		foreach my $seg (split m{/}, $path) { return 0 if ($seg eq '.' || $seg eq '..'); }
		return 1;
	}

	# The only restic invocations the panel uses. The repository is never an argument:
	# it comes from RESTIC_REPOSITORY.
	sub restic_job_argv_ok
	{
		my ($argv) = @_;
		return 0 unless (ref($argv) eq 'ARRAY' && @$argv >= 2 && $argv->[0] eq 'restic');
		foreach my $arg (@$argv)
		{
			return 0 if (!defined($arg) || ref($arg) || $arg =~ /\x00/);
		}
		my ($sub, @args) = @$argv[1 .. $#$argv];

		if ($sub eq 'init')
		{
			return (@args == 0) ? 1 : 0;
		}
		if ($sub eq 'cat')
		{
			return (@args == 1 && $args[0] eq 'config') ? 1 : 0;
		}
		if ($sub eq 'backup')
		{
			# backup <game folder> --exclude <game folder>/restic-restore --tag <kind> --tag home-N --json
			# The exclude keeps restore staging out of the next backup.
			return (@args == 8
				&& restic_arg_home_path_ok($args[0])
				&& $args[1] eq '--exclude' && $args[2] eq $args[0] . '/restic-restore'
				&& $args[3] eq '--tag' && ($args[4] eq 'baseline' || $args[4] eq 'customer')
				&& $args[5] eq '--tag' && $args[6] =~ /^home-[0-9]{1,10}\z/
				&& $args[7] eq '--json') ? 1 : 0;
		}
		if ($sub eq 'restore')
		{
			# restore <snapshot> [--include <game folder path>] --target <game folder path>
			return 0 unless (@args >= 3 && $args[0] =~ /^[a-f0-9]{8,64}\z/);
			my @rest = @args[1 .. $#args];
			if (@rest && $rest[0] eq '--include')
			{
				return 0 unless (@rest >= 2 && restic_arg_home_path_ok($rest[1]));
				splice(@rest, 0, 2);
			}
			return (@rest == 2 && $rest[0] eq '--target' && restic_arg_home_path_ok($rest[1])) ? 1 : 0;
		}
		if ($sub eq 'forget')
		{
			return 0 unless (@args >= 2 && $args[0] eq '--prune');
			foreach my $id (@args[1 .. $#args])
			{
				return 0 unless ($id =~ /^[a-f0-9]{8,64}\z/);
			}
			return 1;
		}
		return 0;
	}

	sub restic_job_env_ok
	{
		my ($env) = @_;
		return 0 unless (ref($env) eq 'HASH');
		foreach my $key (keys %$env)
		{
			return 0 unless ($RESTIC_ENV_KEYS{$key} && defined($env->{$key}) && !ref($env->{$key}));
		}
		return (defined $env->{RESTIC_REPOSITORY} && defined $env->{RESTIC_PASSWORD}) ? 1 : 0;
	}

	# restic_job_start(job_id, argv_json, env_json, check)
	# Returns "1;" + encode_list(state, ...). state: started | exists | error
	sub restic_job_start
	{
		return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
		my ($job_id, $argv_json, $env_json) = decrypt_params(@_);

		return "1;" . encode_list('error', 'bad_job_id') unless restic_job_id_ok($job_id);

		my $argv = eval { JSON::PP->new->utf8->decode($argv_json) };
		return "1;" . encode_list('error', 'bad_argv') unless restic_job_argv_ok($argv);

		my $env = eval { JSON::PP->new->utf8->decode($env_json) };
		return "1;" . encode_list('error', 'bad_env') unless restic_job_env_ok($env);

		my $bin = restic_bin_path();
		return "1;" . encode_list('error', 'no_restic') unless defined $bin;

		utf8::encode($_) for @$argv;
		utf8::encode($_) for values %$env;

		mkpath(RESTIC_JOB_ROOT, 0, 0700) unless -d RESTIC_JOB_ROOT;
		return "1;" . encode_list('error', 'job_root') unless -d RESTIC_JOB_ROOT;

		my $dir = RESTIC_JOB_ROOT . "/$job_id";
		# mkdir is the claim: only one start can create the job directory.
		if (!mkdir($dir, 0700))
		{
			return "1;" . encode_list(-e $dir ? 'exists' : 'error');
		}

		my $supervisor = fork();
		if (!defined $supervisor)
		{
			rmdir($dir);
			return "1;" . encode_list('error', 'fork');
		}

		if ($supervisor == 0)
		{
			# Supervisor: leave the request session, record its own identity, drop the RPC
			# socket, run restic, record the result.
			POSIX::setsid();
			$SIG{CHLD} = 'DEFAULT';
			my $own_start = restic_pid_start_time($$);
			restic_job_write_file("$dir/supervisor.pid", "$$ " . (defined $own_start ? $own_start : 'unknown') . "\n");
			open(STDIN,  '<', '/dev/null');
			open(STDOUT, '>', '/dev/null');
			open(STDERR, '>&', \*STDOUT);
			POSIX::close($_) for (3 .. 255);

			my $worker = fork();
			POSIX::_exit(1) unless defined $worker;

			if ($worker == 0)
			{
				open(STDIN,  '<', '/dev/null');
				open(STDOUT, '>>', "$dir/output.log");
				open(STDERR, '>&', \*STDOUT);
				$SIG{CHLD} = 'DEFAULT';
				delete $ENV{$_} for grep { /^RESTIC_/ } keys %ENV;
				$ENV{$_} = $env->{$_} for keys %$env;
				exec { $bin } @$argv or POSIX::_exit(127);
			}

			waitpid($worker, 0);
			my $code = ($? & 127) ? 128 + ($? & 127) : ($? >> 8);
			restic_job_write_file("$dir/status.json",
				JSON::PP->new->canonical->encode({ state => 'done', exit => $code + 0, finished => time() }));
			POSIX::_exit(0);
		}

		# Answer only once the supervisor's identity is on disk, so the panel never polls
		# a job that the agent cannot yet recognise.
		for (1 .. 100)
		{
			last if -e "$dir/supervisor.pid";
			select(undef, undef, undef, 0.05);
		}
		if (!-e "$dir/supervisor.pid")
		{
			# The supervisor never recorded itself. Stop its whole process group (restic
			# included), clear the directory, and let the panel retry under a new job id.
			kill('KILL', $supervisor);
			kill('KILL', -$supervisor);
			waitpid($supervisor, 0);
			File::Path::remove_tree($dir);
			return "1;" . encode_list('error', 'no_supervisor');
		}
		return "1;" . encode_list('started');
	}

	# restic_job_status(job_id, check)
	# Returns "1;" + encode_list(state, exit_code, output_tail).
	# state: running | done | lost | missing
	sub restic_job_status
	{
		return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
		my ($job_id) = decrypt_params(@_);

		return "1;" . encode_list('error', 'bad_job_id') unless restic_job_id_ok($job_id);

		my $dir = RESTIC_JOB_ROOT . "/$job_id";
		return "1;" . encode_list('missing') unless -d $dir;

		my $read_result = sub {
			my $raw = restic_job_slurp("$dir/status.json");
			return undef unless defined $raw;
			my $parsed = eval { JSON::PP->new->decode($raw) };
			return (ref($parsed) eq 'HASH') ? $parsed : {};
		};

		my ($state, $exit_code) = ('running', '');
		my $result = $read_result->();
		if (!defined $result)
		{
			my $sup = restic_job_slurp("$dir/supervisor.pid");
			my ($pid, $start) = defined $sup ? split(' ', $sup) : ();
			my $alive = 0;
			if (defined $pid && $pid =~ /^\d+\z/ && defined $start && $start =~ /^\d+\z/)
			{
				my $now = restic_pid_start_time($pid);
				$alive = (defined $now && $now eq $start) ? 1 : 0;
			}
			if (!$alive)
			{
				# The supervisor may have written its result just after the checks above.
				$result = $read_result->();
				$state = 'lost' unless defined $result;
			}
		}
		if (defined $result)
		{
			$state = 'done';
			$exit_code = defined $result->{exit} ? $result->{exit} : '';
		}

		my $output = '';
		if (-f "$dir/output.log")
		{
			my $size = -s "$dir/output.log";
			my $from = ($size > RESTIC_OUTPUT_TAIL) ? $size - RESTIC_OUTPUT_TAIL : 0;
			if (open(my $fh, '<', "$dir/output.log"))
			{
				seek($fh, $from, 0);
				local $/;
				$output = <$fh>;
				close($fh);
				$output = '' unless defined $output;
			}
		}

		return "1;" . encode_list($state, $exit_code, $output);
	}


if(CONTAINER_RUNTIME_ENABLED)
{
	my $recover_pid = fork();
	if(defined($recover_pid) && $recover_pid == 0)
	{
		sleep 15;
		eval { container_recover_without_decrypt(); };
		logger "Container recovery failed: $@" if($@);
		exit 0;
	}
}

my $d = Frontier::Daemon::GSP::Forking->new(
			 methods => {
					 is_screen_running				=> \&is_screen_running,
					 server_status					=> \&server_status,
					 force_stop_server				=> \&force_stop_server,
					 universal_start			  	=> \&universal_start,
					 set_desired					=> \&set_desired,
				 container_capabilities			=> \&container_capabilities,
				 container_create				=> \&container_create,
				 container_inspect				=> \&container_inspect,
				 container_start				=> \&container_start,
				 container_stop					=> \&container_stop,
				 container_restart				=> \&container_restart,
				 container_delete				=> \&container_delete,
				 container_game_start			=> \&container_game_start,
				 container_game_stop			=> \&container_game_stop,
				 container_game_status			=> \&container_game_status,
				 container_game_command			=> \&container_game_command,
				 container_game_remove			=> \&container_game_remove,
				 container_game_logs			=> \&container_game_logs,
				 renice_process					=> \&renice_process,
				 cpu_count						=> \&cpu_count,
				 rfile_exists				 	=> \&rfile_exists,
				 quick_chk						=> \&quick_chk,
				 steam_cmd						=> \&steam_cmd,
				 fetch_steam_version			=> \&fetch_steam_version,
				 installed_steam_version		=> \&installed_steam_version,
				 automatic_steam_update			=> \&automatic_steam_update,
				 get_log					  	=> \&get_log,
				 stop_server				  	=> \&stop_server,
				 send_rcon_command				=> \&send_rcon_command,
				 dirlist						=> \&dirlist,
				 dirlistfm						=> \&dirlistfm,
				 readfile					 	=> \&readfile,
				 writefile						=> \&writefile,
				 rebootnow						=> \&rebootnow,
				 what_os					  	=> \&what_os,
				 start_file_download		  	=> \&start_file_download,
				 lock_additional_files          => \&lock_additional_files,
				 is_file_download_in_progress 	=> \&is_file_download_in_progress,
				 uncompress_file			  	=> \&uncompress_file,
				 discover_ips					=> \&discover_ips,
				 mon_stats						=> \&mon_stats,
				 status_sample						=> \&status_sample,
				 agent_resource_snapshot			=> \&agent_resource_snapshot,
				 agent_hardware_inventory			=> \&agent_hardware_inventory,
				 agent_version					=> \&agent_version,
				 exec						 	=> \&exec,
				 clone_home				   		=> \&clone_home,
				 remove_home					=> \&remove_home,
				 restic_job_start				=> \&restic_job_start,
				 restic_job_status				=> \&restic_job_status,
				 start_rsync_install			=> \&start_rsync_install,
				 rsync_progress			   		=> \&rsync_progress,
				 restart_server			   		=> \&restart_server,
				 sudo_exec						=> \&sudo_exec,
				 master_server_update			=> \&master_server_update,
				 secure_path					=> \&secure_path,
				 get_chattr						=> \&get_chattr,
				 ftp_mgr						=> \&ftp_mgr,
				 compress_files					=> \&compress_files,
				 stop_fastdl					=> \&stop_fastdl,
				 restart_fastdl					=> \&restart_fastdl,
				 fastdl_status					=> \&fastdl_status,
				 fastdl_get_aliases				=> \&fastdl_get_aliases,
				 fastdl_add_alias				=> \&fastdl_add_alias,
				 fastdl_del_alias				=> \&fastdl_del_alias,
				 fastdl_get_info				=> \&fastdl_get_info,
				 fastdl_create_config			=> \&fastdl_create_config,
				 agent_restart					=> \&agent_restart,
				 component_update				=> \&component_update,
				 agent_self_update				=> \&agent_self_update,
				 agent_update_status				=> \&agent_update_status,
				 scheduler_add_task				=> \&scheduler_add_task,
				 scheduler_del_task				=> \&scheduler_del_task,
				 scheduler_list_tasks			=> \&scheduler_list_tasks,
				 scheduler_edit_task			=> \&scheduler_edit_task,
				 get_file_part					=> \&get_file_part,
				 stop_update					=> \&stop_update,
				 shell_action					=> \&shell_action,
				 remote_query					=> \&remote_query,
				 send_steam_guard_code  		=> \&send_steam_guard_code,
				 steam_workshop					=> \&steam_workshop,
				 get_workshop_mods_info			=> \&get_workshop_mods_info
			 },
			 debug	 => 4,
			 LocalPort => AGENT_PORT,
			 LocalAddr => AGENT_IP,
			 ReuseAddr => '1'
) or die "Couldn't start GSE Agent: $!";

sub backup_home_log
{
	my ($home_id, $log_file, $console_log_file) = @_;

	my $home_backup_dir = SCREEN_LOGS_DIR . "/home_id_" . $home_id;

	if( ! -e $home_backup_dir )
	{
		if( ! mkdir $home_backup_dir )
		{
			logger "Can not create a backup directory at $home_backup_dir.";
			return 1;
		}
	}

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

	my $backup_file_name =  $mday . $mon . $year . '_' . $hour . 'h' . $min . 'm' . $sec . "s.log";

	my $output_path = $home_backup_dir . "/" . $backup_file_name;

	# Used for deleting log files older than DELETE_LOGS_AFTER
	my @file_list;
	my @find_dirs; # directories to search
	my $now = time(); # get current time
	my $days;
	if((DELETE_LOGS_AFTER =~ /^[+-]?\d+$/) && (DELETE_LOGS_AFTER > 0)){
		$days = DELETE_LOGS_AFTER; # how many days old
	}else{
		$days = 30; # how many days old
	}
	my $seconds_per_day = 60*60*24; # seconds in a day
	my $AGE = $days*$seconds_per_day; # age in seconds
	push (@find_dirs, $home_backup_dir);

	# Create local copy of log file backup in the log_backups folder and current user home directory if SCREEN_LOG_LOCAL = 1
	if(SCREEN_LOG_LOCAL == 1)
	{
		# Create local backups folder
		my $local_log_folder = Path::Class::Dir->new("logs_backup");

		if(!-e $local_log_folder){
			mkdir($local_log_folder);
		}

		# Add full path to @find_dirs so that log files older than DELETE_LOGS_AFTER are deleted
		my $fullpath_to_local_logs = Path::Class::Dir->new(getcwd(), "logs_backup");
		push (@find_dirs, $fullpath_to_local_logs);

		my $log_local = $local_log_folder . "/" . $backup_file_name;

		# Delete the local log file if it already exists
		if(-e $log_local){
			unlink $log_local;
		}

		# If the log file contains UPDATE in the filename, do not allow users to see it since it will contain steam credentials
		# Will return -1 for not existing
		my $isUpdate = index($log_file,SCREEN_TYPE_UPDATE);

		if($isUpdate == -1){
			copy($log_file,$log_local);
		}
	}

	# Delete all files in @find_dirs older than DELETE_LOGS_AFTER days
	find ( sub {
		my $file = $File::Find::name;
		if ( -f $file ) {
			push (@file_list, $file);
		}
	}, @find_dirs);

	# Include the custom console path - and also do a size check on it
	if(defined $console_log_file && $console_log_file ne ""){
		my $path_to_console_file = $console_log_file;
		if( -f $path_to_console_file){
			push (@file_list, $path_to_console_file);

			# Backup and delete this specific file as well if it's over 20MB
			my @stats = stat($path_to_console_file);
			if($stats[7] >= 20971520){
				if(SCREEN_LOG_LOCAL == 1){
					# Copy it to local log folder as well
					my $local_log_folder = Path::Class::Dir->new("logs_backup");
					my $log_local = $local_log_folder . "/" . $backup_file_name . "_console_log";
					copy($path_to_console_file, $log_local);
				}
				# Copy it to the main log folder as well
				move($path_to_console_file,$output_path . "_console_log");
			}
		}
	}

	for my $file (@file_list) {
		if( -f $file ){
			my @stats = stat($file);
			if ($now-$stats[9] > $AGE) {
				unlink $file;
			}
		}
	}

	move($log_file,$output_path);

	return 0;
}

sub get_home_pids
{
	my ($home_id) = @_;
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my ($pid, @pids);

	my $as_user = find_user_by_screen_id($screen_id);

	my $ret = sudo_exec_without_decrypt('screen -ls | grep -E -o "[0-9]+\.'.$screen_id.'"', $as_user);
	my ($retval, $enc_out) = split(/;/, $ret, 2);
	if($retval != 1)
	{
		logger "Unable to get pids, probably a bad sudo password or not in sudoers list.";
		return ();
	}

	$enc_out =~ s/\\n//g;

	my $out = decode_base64($enc_out);

	($pid) = split(/\./, $out, 2);
	if(defined $pid)
	{
		chomp($pid);
		while ($pid =~ /^[0-9]+$/)
		{
			push(@pids,$pid);
			$pid = `pgrep -P $pid`;
			chomp($pid);
		}
	}
	return @pids;
}

sub create_screen_id
{
	my ($screen_type, $home_id) = @_;
	return sprintf("SCREEN_%s_%09d", $screen_type, $home_id);
}

sub create_screen_cmd
{
	my ($screen_id, $exec_cmd) = @_;
	$exec_cmd = replace_Env_Vars($screen_id, "", "", $exec_cmd);
	return
	  sprintf('export WINEDEBUG="fixme-all" && export DISPLAY=:1 && screen -d -m -t "%1$s" -c ' . SCREENRC_FILE . ' -S %1$s %2$s',
			  $screen_id, $exec_cmd);

}

sub shell_single_quote
{
	my ($value) = @_;
	$value = "" unless(defined($value));
	$value =~ s/'/'"'"'/g;
	return "'" . $value . "'";
}


sub handle_lock_command_line{
	my ($command) = @_;
	if(defined $command && $command ne ""){
		if ($command =~ m/{LOCK_FILE}/) {
			$command =~ s/{LOCK_FILE}\s*//g;
			return secure_path_without_decrypt("chattr+i", $command);
		}
	}

	return 0;
}

sub game_content_dir {
	my ($home_path) = @_;
	my $new = "$home_path/_game_content";
	my $old = "$home_path/_gsp_content";
	return (!-d $new && -d $old) ? $old : $new;
}

sub replace_Env_Vars{
	# This function replaces constants from environment variables set in the XML
	my ($screen_id, $homeid, $homepath, $exec_cmd, $game_key) = @_;
	# Accept legacy {GSP_*} token names from older panel templates.
	if (defined $exec_cmd) {
		$exec_cmd =~ s/\{GSP_(HOME_[A-Z_]*)\}/"{GAME_$1}"/ge;
		$exec_cmd =~ s/\{GSP_([A-Z_]+)\}/{$1}/g;
	}

	# Handle steam specific replacements
	if(defined $screen_id && $screen_id ne ""){
		my $screen_id_for_txt_update = substr ($screen_id, rindex($screen_id, '_') + 1);
		my $steamInsFile = $screen_id_for_txt_update . "_install.txt";
		my $steamCMDPath = STEAMCMD_CLIENT_DIR;
		my $fullPath = Path::Class::File->new($steamCMDPath, $steamInsFile);

		# If the install file exists, the game can be auto updated, else it will be ignored by the game for improper syntax
		# To generate the install file, the "Install/Update via Steam" button must be clicked on at least once!
		if(-e $fullPath){
			$exec_cmd =~ s/{STEAM_CMD_DIR}/$steamCMDPath/g;
			$exec_cmd =~ s/{STEAMCMD_INSTALL_FILE}/$steamInsFile/g;
		}
	}


	# Handle home directory replacement
	if(defined $homepath && $homepath ne ""){
		$exec_cmd =~ s/{GAME_HOME_DIR}/$homepath/g;
	}

	# Handle global game shared directory replacement
	if(defined $game_key && $game_key ne ""){
		my $readable_game_key = lc(substr($game_key, 0, rindex($game_key,"_")));
		my $shared_path = Path::Class::Dir->new(SHARED_GAME_TMP_DIR, $readable_game_key);
		# Create the folder if it doesn't exist
		if (!-d $shared_path && !mkdir $shared_path)
		{
			logger "Could not create " . $shared_path . " directory $!.", 1;
		}
		$exec_cmd =~ s/{GAME_SHARED_DIR}/$shared_path/g;
	}

	return $exec_cmd;
}

sub encode_list
{
	my $encoded_content = '';
	if(@_)
	{
		foreach my $line (@_)
		{
			$encoded_content .= encode_base64($line, "") . '\n';
		}
	}
	return $encoded_content;
}

sub decrypt_param
{
	my ($param) = @_;
	$param = decode_base64($param);
	$param = Crypt::XXTEA::decrypt($param, AGENT_KEY);
	$param = decode_base64($param);
	return $param;
}

sub decrypt_params
{
	my @params;
	foreach my $param (@_)
	{
		$param = &decrypt_param($param);
		push(@params, $param);
	}
	return @params;
}

# Reports the explicit container boundary without changing legacy lifecycle routing.
sub container_capabilities
{
	return container_bad_encryption_response_without_decrypt()
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return container_capabilities_without_decrypt();
}

# Handles explicit container create requests through the opt-in runtime boundary.
sub container_create
{
	return container_lifecycle_rpc("create", @_);
}

# Handles explicit container inspect requests through the opt-in runtime boundary.
sub container_inspect
{
	return container_lifecycle_rpc("inspect", @_);
}

# Handles explicit container start requests through the opt-in runtime boundary.
sub container_start
{
	return container_lifecycle_rpc("start", @_);
}

# Handles explicit container stop requests through the opt-in runtime boundary.
sub container_stop
{
	return container_lifecycle_rpc("stop", @_);
}

# Handles explicit container restart requests through the opt-in runtime boundary.
sub container_restart
{
	return container_lifecycle_rpc("restart", @_);
}

# Handles explicit container delete requests through the opt-in runtime boundary.
sub container_delete
{
	return container_lifecycle_rpc("delete", @_);
}

# Builds the capability document the Panel can read before enabling container mode.
sub container_capabilities_without_decrypt
{
	return {
		contract => GSE::Container::Models::CONTRACT_VERSION(),
		success => JSON::PP::true(),
		status => "ok",
		message => "Container runtime boundary is installed. Legacy game-process RPCs remain unchanged.",
		configuration => {
			enabled => CONTAINER_RUNTIME_ENABLED ? JSON::PP::true() : JSON::PP::false(),
			runtime => CONTAINER_RUNTIME,
			docker_binary => CONTAINER_RUNTIME_DOCKER_BINARY,
			data_root => CONTAINER_DATA_ROOT,
			network => CONTAINER_NETWORK,
			approved_images => [ grep { $_ ne "" } split(/[\s,]+/, CONTAINER_ALLOWED_IMAGES) ]
		},
		operations => [
			"container_capabilities",
			"container_create",
			"container_inspect",
			"container_start",
			"container_stop",
			"container_restart",
			"container_delete",
			"container_game_start",
			"container_game_stop",
			"container_game_status",
			"container_game_command",
			"container_game_remove",
			"container_game_logs"
		],
		features => {
			stable_names => JSON::PP::true(),
			ownership_labels => JSON::PP::true(),
			cpu_limits => JSON::PP::true(),
			hard_memory_limits => JSON::PP::true(),
			optional_burst_memory => JSON::PP::true(),
			persistent_volume_mapping => JSON::PP::true(),
			assigned_tcp_udp_port_publishing => JSON::PP::true(),
			structured_results => JSON::PP::true(),
			idempotent_lifecycle_where_observable => JSON::PP::true(),
			logs => JSON::PP::true(),
			console_exec => JSON::PP::false(),
			console_input => JSON::PP::true(),
			game_folder_bind_mount => JSON::PP::true(),
			non_root_user => JSON::PP::true(),
			dropped_capabilities => JSON::PP::true(),
			pid_limits => JSON::PP::true(),
			storage_quota => JSON::PP::false(),
			scoped_files => JSON::PP::false(),
			backup_restore_points => JSON::PP::false(),
			health_monitoring => JSON::PP::true()
		},
		proof_gates => {
			live_docker_poc => JSON::PP::false(),
			steamcmd_outbound_networking => JSON::PP::false(),
			resource_enforcement => JSON::PP::false(),
			port_allocation_enforcement => JSON::PP::false(),
			storage_quota_enforcement => JSON::PP::false()
		},
		compatibility => {
			default_for_legacy_game_records => JSON::PP::false(),
			legacy_lifecycle_rpcs_unchanged => JSON::PP::true(),
			requires_explicit_panel_container_mode => JSON::PP::true()
		}
	};
}

# Runs one explicit container RPC after decrypting and validating the request envelope.
sub container_lifecycle_rpc
{
	my ($operation, @encrypted_params) = @_;
	return container_bad_encryption_response_without_decrypt()
		unless(decrypt_param(pop(@encrypted_params)) eq "Encryption checking OK");
	return container_failure_without_decrypt(
		status => "unsupported",
		code => "container_runtime_disabled",
		category => "unsupported",
		message => "Container runtime is disabled on this agent. Set container_runtime_enabled=1 only after the host passes the Docker proof-of-concept gates.",
		retryable => 0
	) unless(CONTAINER_RUNTIME_ENABLED);
	return container_failure_without_decrypt(
		status => "unsupported",
		code => "unsupported_runtime",
		category => "unsupported",
		message => "Only the docker container runtime adapter is available in this migration slice.",
		retryable => 0
	) unless(CONTAINER_RUNTIME eq "docker");

	my ($payload) = decrypt_params(@encrypted_params);
	my ($request, $request_error) = container_decode_request_without_decrypt($payload);
	return $request_error unless($request);
	return container_failure_without_decrypt(
		status => "validation_failed",
		code => "invalid_contract",
		category => "validation",
		message => "Container request contract must be " . GSE::Container::Models::CONTRACT_VERSION() . ".",
		retryable => 0
	) unless(defined($request->{contract}) && $request->{contract} eq GSE::Container::Models::CONTRACT_VERSION());

	my $runtime = container_runtime_adapter_without_decrypt();
	my $result;
	my $ok = eval {
		if($operation eq "create")
		{
			$result = $runtime->create($request);
		}
		elsif($operation eq "inspect")
		{
			$result = $runtime->inspect($request);
		}
		elsif($operation eq "start")
		{
			$result = $runtime->start($request);
		}
		elsif($operation eq "stop")
		{
			$result = $runtime->stop($request);
		}
		elsif($operation eq "restart")
		{
			$result = $runtime->restart($request);
		}
		elsif($operation eq "delete")
		{
			$result = $runtime->delete($request);
		}
		else
		{
			$result = container_failure_without_decrypt(
				status => "unsupported",
				code => "unsupported_operation",
				category => "unsupported",
				message => "Unsupported container operation.",
				retryable => 0
			);
		}
		1;
	};
	return $result if($ok);
	logger "Container $operation RPC failed unexpectedly: $@";
	return container_failure_without_decrypt(
		status => "failed",
		code => "internal_error",
		category => "internal",
		message => "Container operation failed inside the agent boundary.",
		retryable => 0
	);
}

# Creates the currently supported Docker-backed container runtime adapter.
sub container_runtime_adapter_without_decrypt
{
	return GSE::Container::DockerRuntime->new(
		docker_binary => CONTAINER_RUNTIME_DOCKER_BINARY,
		data_root => CONTAINER_DATA_ROOT
	);
}

# Decodes the JSON request body carried by the encrypted XML-RPC compatibility wrapper.
sub container_decode_request_without_decrypt
{
	my ($payload) = @_;
	return (undef, container_failure_without_decrypt(
		status => "validation_failed",
		code => "invalid_contract",
		category => "validation",
		message => "Container request payload must be a JSON object.",
		retryable => 0
	)) unless(defined($payload) && $payload ne "");
	my $request = eval { JSON::PP->new->decode($payload) };
	return (undef, container_failure_without_decrypt(
		status => "validation_failed",
		code => "invalid_contract",
		category => "validation",
		message => "Container request payload is not valid JSON.",
		retryable => 0
	)) if($@ || ref($request) ne "HASH");
	return ($request, undef);
}

# Builds a structured container failure for transport-level and integration errors.
sub container_failure_without_decrypt
{
	my (%args) = @_;
	return GSE::Container::Result->failure(%args);
}

# Returns the standard bad-encryption response for container RPCs.
sub container_bad_encryption_response_without_decrypt
{
	return container_failure_without_decrypt(
		status => "bad_encryption",
		code => "bad_encryption",
		category => "authorization",
		message => "Bad Encryption Key",
		retryable => 0
	);
}

# ---- Docker game execution backend ----
# A GSE game server that runs in a container keeps its normal management home and gamefiles
# folder. The agent works out every host path itself from the home path the Panel already
# sends for native starts; the Panel only chooses the image, limits and ports.
#   gamefiles            -> /game      (read-write, the customer's files)
#   containers/homes/<id> -> /run/gse  (read-only, launch.sh and console.in written by the agent)

# Returns a JSON text reply for the game container RPCs.
sub container_game_reply
{
	my ($result) = @_;
	return JSON::PP->new->canonical->allow_blessed->convert_blessed->encode($result);
}

sub container_game_failure
{
	my (%args) = @_;
	$args{status} ||= "failed";
	$args{retryable} ||= 0;
	return container_game_reply(container_failure_without_decrypt(%args));
}

# Common checks for every game container RPC: runtime enabled, Docker adapter, JSON request
# with the v1 contract and a target whose home_id matches the one the call is about.
sub container_game_request_without_decrypt
{
	my ($runtime_json, $home_id) = @_;
	return (undef, container_game_failure(
		status => "unsupported",
		code => "container_runtime_disabled",
		category => "unsupported",
		message => "Container runtime is disabled on this agent."
	)) unless(CONTAINER_RUNTIME_ENABLED);
	return (undef, container_game_failure(
		status => "unsupported",
		code => "unsupported_runtime",
		category => "unsupported",
		message => "Only the docker container runtime is available."
	)) unless(CONTAINER_RUNTIME eq "docker");
	my ($request, $request_error) = container_decode_request_without_decrypt($runtime_json);
	return (undef, container_game_reply($request_error)) unless($request);
	return (undef, container_game_failure(
		status => "validation_failed",
		code => "invalid_contract",
		category => "validation",
		message => "Container request contract must be " . GSE::Container::Models::CONTRACT_VERSION() . "."
	)) unless(defined($request->{contract}) && $request->{contract} eq GSE::Container::Models::CONTRACT_VERSION());
	return (undef, container_game_failure(
		status => "validation_failed",
		code => "invalid_contract",
		category => "validation",
		message => "Container target does not belong to this home."
	)) if(defined($home_id) && !(ref($request->{target}) eq "HASH" && defined($request->{target}{home_id}) && "$request->{target}{home_id}" eq "$home_id"));
	return ($request, undef);
}

# The agent-owned folder mounted read-only at /run/gse for one home.
sub container_control_dir_without_decrypt
{
	my ($home_id) = @_;
	return File::Spec->catdir(CONTAINER_DATA_ROOT, "homes", "" . (0 + $home_id));
}

# Resolves and checks everything the container may touch for a home. Nothing here comes
# from the Panel JSON: the home path is the same value native Start receives.
sub container_game_context_without_decrypt
{
	my ($home_id, $home_path, $game_key, $prepare) = @_;
	return (undef, "home_id must be numeric") unless(defined($home_id) && $home_id =~ /^\d+$/ && $home_id > 0);
	$home_path =~ s{/+$}{} if(defined($home_path));
	return (undef, "management home is missing") unless(defined($home_path) && $home_path ne "" && -d $home_path);
	my ($root_ok, $game_root, $root_error) = resolve_game_root_without_decrypt($home_path, $game_key);
	return (undef, $root_error) unless($root_ok);
	return (undef, "gamefiles folder is missing") unless(-d $game_root);
	return (undef, "gamefiles folder must not be a symlink") if(-l $game_root);

	my ($owner, $group) = gm_home_owner($home_id, $prepare ? 1 : 0);
	my @owner_pw = getpwnam($owner);
	my $uid = @owner_pw ? $owner_pw[2] : undef;
	my $gid = getgrnam($group);
	return (undef, "server user $owner does not exist") unless(defined($uid));
	return (undef, "server group $group does not exist") unless(defined($gid));
	return (undef, "game servers must not run as root") if($uid == 0 || $gid == 0);
	set_path_ownership($owner, $group, $home_path, 1) if($prepare);

	my $game_root_real = Cwd::abs_path($game_root);
	return (undef, "gamefiles folder cannot be resolved") unless(defined($game_root_real));
	my $home_real = Cwd::abs_path($home_path);
	return (undef, "gamefiles folder escapes the management home")
		unless(defined($home_real) && index($game_root_real, "$home_real/") == 0);
	my @st = lstat($game_root_real);
	return (undef, "gamefiles folder is not owned by $owner") unless(@st && $st[4] == $uid);

	my $control_dir = container_control_dir_without_decrypt($home_id);
	if($prepare)
	{
		mkpath($control_dir) unless(-d $control_dir);
		chmod(0750, $control_dir);
		chmod(0750, File::Spec->catdir(CONTAINER_DATA_ROOT, "homes"));
		chmod(0750, CONTAINER_DATA_ROOT);
		chown(-1, $gid, $control_dir, File::Spec->catdir(CONTAINER_DATA_ROOT, "homes"), CONTAINER_DATA_ROOT);
	}
	return (undef, "container control folder is missing") unless(-d $control_dir);
	my $control_real = Cwd::abs_path($control_dir);

	my @allowed = grep { $_ ne "" } split(/[\s,]+/, CONTAINER_ALLOWED_IMAGES);
	my %context = (
		home_path => $home_path,
		game_root => $game_root_real,
		control_dir => $control_real,
		owner => $owner,
		group => $group,
		forbidden_roots => [ AGENT_RUN_DIR ],
		allowed_image_prefixes => \@allowed,
		network => CONTAINER_NETWORK,
		workdir => CONTAINER_GAME_MOUNT,
		entrypoint => "/bin/sh",
		command => [ CONTAINER_CONTROL_MOUNT . "/launch.sh" ],
		environment => {
			HOME => "/tmp",
			TINI_KILL_PROCESS_GROUP => "1",
			GSE_HOME_ID => "" . $home_id
		},
		mounts => [
			{
				name => "gamefiles",
				host_path => $game_root_real,
				container_path => CONTAINER_GAME_MOUNT,
				mode => "rw"
			},
			{
				name => "control",
				host_path => $control_real,
				container_path => CONTAINER_CONTROL_MOUNT,
				mode => "ro",
				allow_inside_agent => 1
			}
		],
		run_as => { uid => $uid, gid => $gid }
	);
	return (\%context, "");
}

# Single-quotes a value for /bin/sh.
sub container_sh_quote
{
	my ($value) = @_;
	$value = "" unless(defined($value));
	$value =~ s/'/'\\''/g;
	return "'$value'";
}

# Writes launch.sh (run inside the container) and an empty console.in. The startup line,
# environment and pre-start commands are the same ones native Start uses, with host paths
# under gamefiles mapped to /game. They run inside the container, never on the host.
sub container_write_launch_without_decrypt
{
	my ($context, $home_id, $game_key, $server_exe, $run_dir, $startup_cmd, $preStart, $envVars) = @_;
	my $game_root = $context->{game_root};
	my ($payload_ok, $binary_dir, $payload_error) = resolve_game_payload_path_without_decrypt($context->{home_path}, $game_key, $run_dir);
	return (0, $payload_error) unless($payload_ok);
	my $binary_real = Cwd::abs_path($binary_dir);
	return (0, "server binary folder is missing") unless(defined($binary_real) && -d $binary_real);
	return (0, "server binary folder is outside gamefiles")
		unless($binary_real eq $game_root || index($binary_real, "$game_root/") == 0);
	(my $relative = substr($binary_real, length($game_root))) =~ s{^/+}{};
	my $workdir = CONTAINER_GAME_MOUNT . ($relative ne "" ? "/$relative" : "");

	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my $map = sub {
		my ($text) = @_;
		$text = replace_Env_Vars($screen_id, $home_id, $game_root, $text, $game_key);
		$text =~ s/\Q$game_root\E/@{[CONTAINER_GAME_MOUNT]}/g;
		$text =~ s/\Q$context->{home_path}\/gamefiles\E/@{[CONTAINER_GAME_MOUNT]}/g;
		return $text;
	};
	my $startup = $map->(defined($startup_cmd) ? $startup_cmd : "");
	my $extension = lc(substr(defined($server_exe) ? $server_exe : "", -4));
	return (0, "Windows executables cannot run in a Linux container") if($extension eq ".exe" || $extension eq ".bat");
	return (0, "server executable name is invalid") unless(defined($server_exe) && $server_exe ne "" && $server_exe !~ m{(^|/)\.\.(/|$)} && $server_exe !~ /[\x00-\x1f]/);
	my $command = $extension eq ".jar" ? $startup : container_sh_quote("$workdir/$server_exe") . " " . $startup;
	return (0, "startup command is empty") if($command =~ /\A\s*\z/);

	my @lines = (
		"#!/bin/sh",
		"# Written by the GSE agent at every start. Changes here are overwritten.",
		"umask 0002",
		"cd " . container_sh_quote($workdir) . " || { echo 'GSE: game folder missing' >&2; exit 1; }",
	);
	foreach my $line (split /[\r\n]+/, (defined $envVars ? $envVars : ""))
	{
		$line = $map->($line);
		push @lines, $line if($line =~ /\S/);
	}
	foreach my $line (split /[\r\n]+/, (defined $preStart ? $preStart : ""))
	{
		$line = $map->($line);
		push @lines, $line if($line =~ /\S/);
	}
	push @lines, (
		"# Console input: the agent appends lines to /run/gse/console.in.",
		"rm -f /tmp/gse-console; mkfifo /tmp/gse-console || exit 1",
		"tail -n 0 -F " . CONTAINER_CONTROL_MOUNT . "/console.in > /tmp/gse-console 2>/dev/null &",
		"GSE_TAIL=\$!",
		"$command < /tmp/gse-console &",
		"GSE_GAME=\$!",
		"trap 'kill -TERM \"\$GSE_GAME\" 2>/dev/null' TERM INT",
		"GSE_STATUS=0",
		"while kill -0 \"\$GSE_GAME\" 2>/dev/null; do wait \"\$GSE_GAME\"; GSE_STATUS=\$?; done",
		"kill \"\$GSE_TAIL\" 2>/dev/null",
		"exit \$GSE_STATUS"
	);
	my $dir = $context->{control_dir};
	my $tmp = "$dir/.launch.sh.$$";
	unlink $tmp;
	sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0640) or return (0, "cannot write launch script: $!");
	print $fh join("\n", @lines) . "\n";
	close($fh);
	chmod(0640, $tmp);
	rename($tmp, "$dir/launch.sh") or return (0, "cannot install launch script: $!");
	unlink "$dir/console.in";
	sysopen(my $in, "$dir/console.in", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0640) or return (0, "cannot create console input: $!");
	close($in);
	chmod(0640, "$dir/console.in");
	return (1, "");
}

# Small agent-owned state files in the control folder (not visible to the game).
sub container_write_control_file_without_decrypt
{
	my ($home_id, $name, $value) = @_;
	return 0 unless($name =~ /\A[a-z_]+\z/);
	my $dir = container_control_dir_without_decrypt($home_id);
	return 0 unless(-d $dir);
	my $tmp = "$dir/.$name.$$";
	unlink $tmp;
	sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0640) or return 0;
	print $fh ((defined($value) ? $value : "") . "\n");
	close($fh);
	return rename($tmp, "$dir/$name") ? 1 : 0;
}

sub container_read_control_file_without_decrypt
{
	my ($home_id, $name) = @_;
	my $path = container_control_dir_without_decrypt($home_id) . "/$name";
	return "" if(-l $path || !-f $path);
	open(my $fh, '<', $path) or return "";
	my $value = <$fh>;
	close($fh);
	$value = "" unless(defined($value));
	chomp $value;
	return $value;
}

# After an agent or host restart, starts the containers whose server was running before
# (desired RUNNING). Docker's on-failure policy only restarts crashes, never a reboot.
sub container_recover_without_decrypt
{
	return unless(CONTAINER_RUNTIME_ENABLED && CONTAINER_RUNTIME eq "docker");
	my $homes = File::Spec->catdir(CONTAINER_DATA_ROOT, "homes");
	opendir(my $dh, $homes) or return;
	my @ids = grep { /^\d+$/ } readdir($dh);
	closedir($dh);
	my $runner = GSE::Container::CommandRunner->new();
	my $runtime = container_runtime_adapter_without_decrypt();
	foreach my $home_id (@ids)
	{
		next unless(container_read_control_file_without_decrypt($home_id, "desired") eq "RUNNING");
		my $list = $runner->run([CONTAINER_RUNTIME_DOCKER_BINARY, "ps", "-a", "--filter", "label=gse.managed=true",
			"--filter", "label=gse.home_id=$home_id", "--filter", "status=exited", "--filter", "status=created",
			"--format", "{{.Names}}"], 30);
		next unless($list->{exit_code} == 0);
		foreach my $name (grep { /\Agse-h\d+-a\d+\z/ } split(/\s+/, $list->{stdout}))
		{
			my $labels_run = $runner->run([CONTAINER_RUNTIME_DOCKER_BINARY, "container", "inspect", "--format", "{{json .Config.Labels}}", $name], 30);
			my $labels = eval { JSON::PP->new->decode($labels_run->{stdout}) } || {};
			my $target = { map { $_ => $labels->{"gse.$_"} } qw(server_id home_id allocation_id owner_user_id) };
			my ($context) = container_game_context_without_decrypt($home_id,
				container_read_control_file_without_decrypt($home_id, "home_path"),
				container_read_control_file_without_decrypt($home_id, "game_key"), 0);
			if(!$context)
			{
				logger "Container recovery for HOME ID:$home_id skipped: the server folder failed its checks.";
				next;
			}
			my $started = $runtime->start({ contract => GSE::Container::Models::CONTRACT_VERSION(), target => $target }, $context);
			logger "Container recovery for HOME ID:$home_id ($name): " . ($started->{success} ? "started" : ($started->{error}{message} || "failed"));
		}
	}
}

# True when a native (screen) copy of this home is running.
sub container_native_running_without_decrypt
{
	my ($home_id) = @_;
	return 1 if(is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1);
	my @pids = get_home_pids($home_id);
	return @pids ? 1 : 0;
}

# True when a GSE-managed container for this home is running (any allocation).
sub container_running_for_home_without_decrypt
{
	my ($home_id) = @_;
	return 0 unless(CONTAINER_RUNTIME_ENABLED && CONTAINER_RUNTIME eq "docker");
	my $run = GSE::Container::CommandRunner->new()->run([CONTAINER_RUNTIME_DOCKER_BINARY, "ps", "-q",
		"--filter", "label=gse.managed=true", "--filter", "label=gse.home_id=" . (0 + $home_id),
		"--filter", "status=running"], 20);
	return ($run->{exit_code} == 0 && $run->{stdout} =~ /\S/) ? 1 : 0;
}

# Start: same arguments as universal_start plus the runtime JSON. Creates (or safely recreates)
# the container, writes launch.sh and starts it. Never falls back to a native start.
sub container_game_start
{
	return container_game_reply(container_bad_encryption_response_without_decrypt())
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $home_path, $server_exe, $run_dir, $startup_cmd, $server_port, $server_ip,
		$cpu, $nice, $preStart, $envVars, $game_key, $console_log, $runtime_json) = decrypt_params(@_);
	logger "Container start request received for HOME ID:$home_id.";
	my ($request, $request_error) = container_game_request_without_decrypt($runtime_json, $home_id);
	return $request_error unless($request);
	return container_game_failure(
		status => "conflict", code => "native_running", category => "conflict",
		message => "This server is running natively; stop it before starting the container."
	) if(container_native_running_without_decrypt($home_id));

	my ($context, $context_error) = container_game_context_without_decrypt($home_id, $home_path, $game_key, 1);
	return container_game_failure(
		status => "validation_failed", code => "invalid_volume_path", category => "validation",
		message => "Server folder failed the container safety checks: $context_error"
	) unless($context);
	return container_game_failure(
		status => "unsupported", code => "no_approved_images", category => "unsupported",
		message => "No container images are approved on this agent (container_allowed_images)."
	) unless(@{$context->{allowed_image_prefixes}});

	my ($launch_ok, $launch_error) = container_write_launch_without_decrypt($context, $home_id, $game_key,
		$server_exe, $run_dir, $startup_cmd, $preStart, $envVars);
	return container_game_failure(
		status => "validation_failed", code => "invalid_launch", category => "validation",
		message => "Cannot prepare the container start: $launch_error"
	) unless($launch_ok);

	# The native watchdog must never relaunch this home outside the container. It finds the
	# home's folder through the home index, so record the home first (as native Start does).
	gm_remember_home($home_id, $home_path);
	gm()->set_desired($home_id, "STOPPED");
	container_write_control_file_without_decrypt($home_id, "home_path", $home_path);
	container_write_control_file_without_decrypt($home_id, "game_key", $game_key);

	my $runtime = container_runtime_adapter_without_decrypt();
	$request->{recreate_if_changed} = 1;
	my $created = $runtime->create($request, $context);
	# A running container with an older configuration keeps running; it is recreated on the
	# next start after a stop.
	return container_game_reply($created)
		unless($created->{success} || (($created->{error}{code} || "") eq "config_changed" && $created->{state} eq "running"));
	my $started = $runtime->start($request, $context);
	if($started->{success})
	{
		container_write_control_file_without_decrypt($home_id, "desired", "RUNNING");
		backup_home_log($home_id, Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog." . create_screen_id(SCREEN_TYPE_HOME, $home_id)),
			$context->{game_root} . "/" . (defined($console_log) ? $console_log : ""));
		queue_agent_event("server_process_started", "info", {
			home_id => $home_id,
			game_home_path => $home_path,
			game_root => $context->{game_root},
			ip => $server_ip,
			game_port => $server_port,
			execution_backend => "docker",
			container_name => $started->{target}{container_name},
			actual_process_state => "starting",
			actual_port_state => "pending_validation",
			message => "Container started; waiting for the game port."
		});
		$started->{state} = "starting";
		$started->{result}{created} = $created->{status};
	}
	return container_game_reply($started);
}

# Stop: sends the game's own stop command to the console, waits up to timeout_seconds for a
# clean exit (world save), then lets Docker stop it (SIGTERM, then SIGKILL after 15 s).
sub container_game_stop
{
	return container_game_reply(container_bad_encryption_response_without_decrypt())
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $runtime_json) = decrypt_params(@_);
	my ($request, $request_error) = container_game_request_without_decrypt($runtime_json, $home_id);
	return $request_error unless($request);
	container_write_control_file_without_decrypt($home_id, "desired", "STOPPED");
	my $runtime = container_runtime_adapter_without_decrypt();
	my $current = $runtime->inspect($request);
	if(!$current->{success})
	{
		return container_game_reply(GSE::Container::Result->success(
			status => "already_absent", state => "stopped", message => "No container exists for this server.",
			target => $current->{target} || {}
		)) if(($current->{error}{code} || "") eq "container_not_found");
		return container_game_reply($current);
	}
	my $graceful = "skipped";
	if($current->{state} eq "running" && defined($request->{stop_command}) && $request->{stop_command} =~ /\A[^\x00-\x1f\x7f]{1,256}\z/)
	{
		my $console = container_control_dir_without_decrypt($home_id) . "/console.in";
		if(!-l $console && open(my $fh, '>>', $console))
		{
			print $fh $request->{stop_command} . "\n";
			close($fh);
			my $deadline = time() + GSE::Container::Models::_bounded_int($request->{timeout_seconds}, 60, 5, 300);
			$graceful = "timeout";
			while(time() < $deadline)
			{
				sleep 1;
				my $now = $runtime->inspect($request);
				if($now->{success} && $now->{state} ne "running")
				{
					$graceful = "clean";
					last;
				}
			}
		}
	}
	my $stopped = $runtime->stop({ %$request, timeout_seconds => 15 });
	$stopped->{result}{graceful} = $graceful if($stopped->{success});
	logger "Container stop for HOME ID:$home_id: " . ($stopped->{status} || "failed") . " (graceful: $graceful).";
	return container_game_reply($stopped);
}

# Status: container state plus game readiness. Running is not online: the game port must
# accept a connection on the container's own address (the host port always answers via Docker).
sub container_game_status
{
	return container_game_reply(container_bad_encryption_response_without_decrypt())
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $runtime_json) = decrypt_params(@_);
	my ($request, $request_error) = container_game_request_without_decrypt($runtime_json, $home_id);
	return $request_error unless($request);
	my $runtime = container_runtime_adapter_without_decrypt();
	my $current = $runtime->inspect($request);
	if(!$current->{success})
	{
		my $code = $current->{error}{code} || "";
		$current->{result}{game_state} = $code eq "container_not_found" ? "STOPPED"
			: $code eq "runtime_unavailable" ? "RUNTIME_UNAVAILABLE" : "UNKNOWN";
		return container_game_reply($current);
	}
	my $summary = $current->{result}{summary} || {};
	my $game_state = "UNKNOWN";
	if($current->{state} eq "running")
	{
		$game_state = "STARTING";
		my $port = $request->{readiness_port};
		if(defined($port) && $port =~ /^\d+$/)
		{
			my $ip_run = GSE::Container::CommandRunner->new()->run([CONTAINER_RUNTIME_DOCKER_BINARY, "container", "inspect", "--format",
				"{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", $current->{target}{container_name}], 20);
			my ($ip) = ($ip_run->{stdout} || "") =~ /(\d+\.\d+\.\d+\.\d+)/;
			if($ip)
			{
				my $socket = IO::Socket::INET->new(PeerAddr => $ip, PeerPort => $port, Proto => "tcp", Timeout => 2);
				if($socket)
				{
					$game_state = "ONLINE";
					close($socket);
				}
			}
		}
		elsif(($request->{readiness} || "") eq "running")
		{
			$game_state = "ONLINE";
		}
		if($request->{include_stats})
		{
			my $stats = $runtime->stats($request);
			$current->{result}{stats} = $stats->{result} if($stats->{success});
		}
	}
	elsif($current->{state} eq "oom") { $game_state = "OOM"; }
	elsif($current->{state} eq "created") { $game_state = "CREATED"; }
	elsif($current->{state} eq "restarting") { $game_state = "STARTING"; }
	elsif($current->{state} eq "stopped")
	{
		$game_state = (defined($summary->{exit_code}) && $summary->{exit_code} != 0 && $summary->{exit_code} != 143) ? "FAILED" : "STOPPED";
	}
	$current->{result}{game_state} = $game_state;
	return container_game_reply($current);
}

# Console input: one line appended to the game's console, only while it runs.
sub container_game_command
{
	return container_game_reply(container_bad_encryption_response_without_decrypt())
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $runtime_json, $line) = decrypt_params(@_);
	my ($request, $request_error) = container_game_request_without_decrypt($runtime_json, $home_id);
	return $request_error unless($request);
	return container_game_failure(
		status => "validation_failed", code => "invalid_command", category => "validation",
		message => "Console command must be one line of at most 1024 characters."
	) unless(defined($line) && $line =~ /\A[^\x00-\x1f\x7f]{1,1024}\z/);
	my $runtime = container_runtime_adapter_without_decrypt();
	my $current = $runtime->inspect($request);
	return container_game_reply($current) unless($current->{success});
	return container_game_failure(
		status => "conflict", code => "not_running", category => "conflict",
		message => "The server is not running."
	) unless($current->{state} eq "running");
	my $console = container_control_dir_without_decrypt($home_id) . "/console.in";
	return container_game_failure(code => "console_unavailable", category => "runtime", message => "Console input is not available.")
		if(-l $console || !-f $console);
	open(my $fh, '>>', $console) or return container_game_failure(code => "console_unavailable", category => "runtime", message => "Console input is not available.");
	print $fh "$line\n";
	close($fh);
	return container_game_reply(GSE::Container::Result->success(
		status => "sent", state => "running", message => "Command sent.", target => $current->{target}
	));
}

# Remove: deletes a stopped container. The game files stay on the host.
sub container_game_remove
{
	return container_game_reply(container_bad_encryption_response_without_decrypt())
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $runtime_json) = decrypt_params(@_);
	my ($request, $request_error) = container_game_request_without_decrypt($runtime_json, $home_id);
	return $request_error unless($request);
	return container_game_reply(container_runtime_adapter_without_decrypt()->delete({ %$request, allow_absent => 1 }));
}

# Output the container itself printed (bounded), for when the game writes no log file yet.
sub container_game_logs
{
	return container_game_reply(container_bad_encryption_response_without_decrypt())
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $runtime_json, $lines) = decrypt_params(@_);
	my ($request, $request_error) = container_game_request_without_decrypt($runtime_json, $home_id);
	return $request_error unless($request);
	return container_game_reply(container_runtime_adapter_without_decrypt()->logs({ %$request, lines => $lines }));
}

sub check_steam_cmd_client
{
	if (STEAM_LICENSE ne STEAM_LICENSE_OK)
	{
		logger "Steam license not accepted, stopping Steam client check.";
		return 0;
	}
	if (!-d STEAMCMD_CLIENT_DIR)
	{
		logger "SteamCMD is unavailable. Expected bundled bootstrap directory "
		  . STEAMCMD_CLIENT_DIR
		  . ". Repair or reinstall the Linux agent to restore steamcmd/steamcmd.sh.";
		return -1;
	}
	if (!-w STEAMCMD_CLIENT_DIR)
	{
		logger "Steam client dir '"
		  . STEAMCMD_CLIENT_DIR
		  . "' not writable. Unable to run SteamCMD.";
		return -1;
	}
	if (!-f STEAMCMD_CLIENT_BIN)
	{
		logger "SteamCMD is unavailable. Expected bundled bootstrap executable "
		  . STEAMCMD_CLIENT_BIN
		  . ". Repair or reinstall the Linux agent to restore steamcmd/steamcmd.sh. Official manual download: https://media.steampowered.com/client/steamcmd_linux.tar.gz";
		return -1;
	}
	if (!-x STEAMCMD_CLIENT_BIN)
	{
		if ( ! chmod 0755, STEAMCMD_CLIENT_BIN )
		{
			logger "Unable to apply execution permission to ".STEAMCMD_CLIENT_BIN.".";
		}
	}
	return 1;
}

sub is_screen_running
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($screen_type, $home_id) = decrypt_params(@_);
	return is_screen_running_without_decrypt($screen_type, $home_id);
}

sub is_screen_running_without_decrypt
{
	my ($screen_type, $home_id) = @_;

	my $screen_id = create_screen_id($screen_type, $home_id);

	my $as_user = find_user_by_screen_id($screen_id);

	my $ret = sudo_exec_without_decrypt('screen -list | grep '.$screen_id, $as_user);

	my ($retval, $enc_out) = split(/;/, $ret, 2);

	if($retval != 1)
	{
		return 0;
	}

	my $is_running = " ";

	if( defined($enc_out) )
	{
		$enc_out =~ s/\\n//g;
		$is_running = decode_base64($enc_out);
	}

	if ($is_running =~ /^\s*$/)
	{
		return 0;
	}
	else
	{
		return 1;
	}
}

sub server_status
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return server_status_without_decrypt(decrypt_params(@_));
}

sub get_status_hint_path
{
	my ($home_id) = @_;
	$home_id =~ s/[^0-9]//g;
	return Path::Class::File->new(GAME_STARTUP_DIR, "status-$home_id");
}

sub write_status_hint
{
	my ($home_id, $state) = @_;
	my $hint_file = get_status_hint_path($home_id);
	if(open(STATUSHINT, '>', $hint_file))
	{
		print STATUSHINT time() . "," . $state;
		close(STATUSHINT);
	}
}

sub read_status_hint
{
	my ($home_id) = @_;
	my $hint_file = get_status_hint_path($home_id);
	return (0, "") unless(-e $hint_file);
	open(STATUSHINT, '<', $hint_file) or return (0, "");
	my $line = <STATUSHINT>;
	close(STATUSHINT);
	chomp($line);
	my ($timestamp, $state) = split(/,/, $line, 2);
	$timestamp = 0 unless(defined($timestamp) && $timestamp =~ /^\d+$/);
	$state = "" unless(defined($state));
	return ($timestamp, $state);
}

# Return the two authoritative desired-state marker paths for one management home.
sub desired_state_paths_without_decrypt
{
	my ($home_path) = @_;
	return ("", "") unless(defined($home_path) && $home_path ne "");
	return ("$home_path/status.running", "$home_path/status.stopped");
}

# Atomically publish exactly one desired lifecycle state marker in management_home.
sub write_desired_state_without_decrypt
{
	my ($home_path, $state) = @_;
	return 0 unless(defined($home_path) && -d $home_path);
	return 0 unless(defined($state) && $state =~ /^(running|stopped)$/);
	my ($running_file, $stopped_file) = desired_state_paths_without_decrypt($home_path);
	my $target_file = $state eq "running" ? $running_file : $stopped_file;
	my $opposite_file = $state eq "running" ? $stopped_file : $running_file;
	my $tmp_file = "$target_file.$$." . time() . ".tmp";

	unlink($opposite_file) if(-e $opposite_file);
	if(open(my $STATE, '>', $tmp_file))
	{
		print $STATE time() . ",$state\n";
		close($STATE);
		chmod 0644, $tmp_file;
		return 0 unless(rename($tmp_file, $target_file));
		unlink($opposite_file) if(-e $opposite_file);
		return 1;
	}
	return 0;
}


# Remove lifecycle PID/timestamp metadata after verification has proven the home is inactive.
sub clear_lifecycle_runtime_files_without_decrypt
{
	my ($home_id, $home_path) = @_;
	clear_pid_metadata($home_id);
	if(defined($home_path) && $home_path ne "")
	{
		foreach my $name ("watchdog.pid", "bot.pid", "game.pid", "game.launch_ts")
		{
			my $path = "$home_path/$name";
			unlink($path) if(-e $path);
		}
	}
	my $hint_file = get_status_hint_path($home_id);
	unlink($hint_file) if(-e $hint_file);
}

sub get_pid_metadata_path
{
	my ($home_id) = @_;
	$home_id =~ s/[^0-9]//g;
	return Path::Class::File->new(SERVER_RUNTIME_DIR, "pid-$home_id.kv");
}


sub read_pid_metadata
{
	my ($home_id) = @_;
	my %values;
	my $file = get_pid_metadata_path($home_id);
	return \%values unless(-e $file);
	if(open(PIDMETA, '<', $file))
	{
		while(my $line = <PIDMETA>)
		{
			chomp($line);
			next unless($line =~ /^([^=]+)=(.*)$/);
			$values{$1} = $2;
		}
		close(PIDMETA);
	}
	return \%values;
}

sub clear_pid_metadata
{
	my ($home_id) = @_;
	my $file = get_pid_metadata_path($home_id);
	unlink($file) if(-e $file);
}

sub is_pid_alive_without_decrypt
{
	my ($pid) = @_;
	return 0 unless(defined($pid) && $pid =~ /^\d+$/ && $pid > 0);
	return 1 if(kill(0, $pid));
	# EPERM means the process exists but belongs to another user (a game running as gamehomeNNN).
	return $!{EPERM} ? 1 : 0;
}

sub read_proc_text_without_decrypt
{
	my ($path) = @_;
	return "" unless(defined($path) && -r $path);
	open(my $PROC, '<', $path) or return "";
	local $/;
	my $text = <$PROC>;
	close($PROC);
	return defined($text) ? $text : "";
}

sub proc_cmdline_without_decrypt
{
	my ($pid) = @_;
	my $cmdline = read_proc_text_without_decrypt("/proc/$pid/cmdline");
	$cmdline =~ s/\0/ /g;
	$cmdline =~ s/\s+$//;
	return $cmdline;
}

sub proc_comm_without_decrypt
{
	my ($pid) = @_;
	my $comm = read_proc_text_without_decrypt("/proc/$pid/comm");
	chomp($comm);
	return $comm;
}

sub proc_parent_pid_without_decrypt
{
	my ($pid) = @_;
	my $status = read_proc_text_without_decrypt("/proc/$pid/status");
	return $1 if($status =~ /^PPid:\s+([0-9]+)/m);
	return "";
}

sub process_lineage_contains_without_decrypt
{
	my ($pid, $ancestor) = @_;
	return 0 unless(defined($pid) && $pid =~ /^\d+$/ && defined($ancestor) && $ancestor =~ /^\d+$/);
	my %seen;
	while($pid =~ /^\d+$/ && $pid > 1 && !$seen{$pid})
	{
		return 1 if($pid == $ancestor);
		$seen{$pid} = 1;
		$pid = proc_parent_pid_without_decrypt($pid);
	}
	return 0;
}

sub current_agent_protected_pids_without_decrypt
{
	my %protected = ( 0 => 1, 1 => 1, $$ => 1 );
	my $pid = $$;
	my %seen;
	while($pid =~ /^\d+$/ && $pid > 1 && !$seen{$pid})
	{
		$protected{$pid} = 1;
		$seen{$pid} = 1;
		$pid = proc_parent_pid_without_decrypt($pid);
	}
	return \%protected;
}

sub process_is_kernel_thread_without_decrypt
{
	my ($pid) = @_;
	return 0 unless(defined($pid) && $pid =~ /^\d+$/);
	return 0 unless(proc_cmdline_without_decrypt($pid) eq "");
	return proc_parent_pid_without_decrypt($pid) eq "2" ? 1 : 0;
}

sub process_is_protected_without_decrypt
{
	my ($pid) = @_;
	return 1 unless(defined($pid) && $pid =~ /^\d+$/);
	return 1 if($pid <= 1);
	my $protected = current_agent_protected_pids_without_decrypt();
	return 1 if($protected->{$pid});
	return 1 if(process_lineage_contains_without_decrypt($pid, $$));
	return 1 if(process_is_kernel_thread_without_decrypt($pid));
	my $comm = proc_comm_without_decrypt($pid);
	my $cmdline = proc_cmdline_without_decrypt($pid);
	return 1 if($comm =~ /^(systemd|init|sshd|ssh|NetworkManager|systemd-networkd|systemd-resolved|dbus-daemon|sudo|su)$/);
	return 1 if($cmdline =~ /\b(?:agent_core\.pl|agent_core_run|systemctl|apt|apt-get|dpkg|sshd|NetworkManager|systemd-networkd|systemd-resolved)\b/);
	return 0;
}

sub path_is_under_without_decrypt
{
	my ($path, $root) = @_;
	return 0 unless(defined($path) && defined($root) && $path ne "" && $root ne "");
	my $abs_root = Cwd::abs_path($root);
	return 0 unless(defined($abs_root) && $abs_root ne "");
	my $abs_path = Cwd::abs_path($path);
	return 0 unless(defined($abs_path) && $abs_path ne "");
	return 1 if($abs_path eq $abs_root);
	return index($abs_path, "$abs_root/") == 0 ? 1 : 0;
}

# Normalize a Linux agent path for contract checks without requiring the target to exist.
sub normalize_agent_path_without_decrypt
{
	my ($path) = @_;
	return "" unless(defined($path));
	$path =~ s/\\/\//g;
	$path =~ s/^\s+|\s+$//g;
	$path =~ s#/+#/#g;
	$path =~ s#/$## if($path ne "/");
	return $path;
}

# Validate XML game_key as the single safe directory component used for game_root.
sub validate_game_key_without_decrypt
{
	my ($game_key) = @_;
	return (0, "Game key is empty or contains surrounding whitespace.") unless(defined($game_key) && $game_key ne "" && $game_key eq normalize_agent_path_without_decrypt($game_key));
	return (0, "Game key contains a control character.") if($game_key =~ /[\x00-\x1F\x7F]/);
	return (0, "Game key must be a single directory name, not a path.") if($game_key =~ m{[\\/]});
	return (0, "Game key must not contain a drive prefix.") if($game_key =~ /^[A-Za-z]:/ || index($game_key, ":") >= 0);
	return (0, "Game key must not contain traversal segments.") if($game_key eq "." || $game_key eq ".." || index($game_key, "..") >= 0);
	return (0, "Game key contains characters that are not safe for a directory name.") unless($game_key =~ /^[A-Za-z0-9._-]+$/);
	return (0, "Game key must not end with a dot.") if(substr($game_key, -1) eq ".");
	my ($name_part) = split(/\./, uc($game_key), 2);
	my %reserved = map { $_ => 1 } qw(CON PRN AUX NUL CONIN$ CONOUT$);
	for(my $i = 1; $i <= 9; $i++)
	{
		$reserved{"COM$i"} = 1;
		$reserved{"LPT$i"} = 1;
	}
	return (0, "Game key uses a reserved device name.") if($reserved{$name_part});
	return (1, "");
}

# Return true when candidate is management_home itself or a descendant.
sub normalized_path_is_at_or_under_without_decrypt
{
	my ($candidate, $root) = @_;
	$candidate = normalize_agent_path_without_decrypt($candidate);
	$root = normalize_agent_path_without_decrypt($root);
	return 0 if($candidate eq "" || $root eq "");
	return 1 if($candidate eq $root);
	return index($candidate, "$root/") == 0 ? 1 : 0;
}

# game_root is management_home/gamefiles (as on Windows). The XML game_key is still validated.
sub resolve_game_root_without_decrypt
{
	my ($management_home, $game_key) = @_;
	$management_home = normalize_agent_path_without_decrypt($management_home);
	return (0, "", "Management home is empty.") if($management_home eq "");
	my ($valid_key, $key_error) = validate_game_key_without_decrypt($game_key);
	return (0, "", $key_error) unless($valid_key);
	my $game_root = normalize_agent_path_without_decrypt("$management_home/gamefiles");
	if(!normalized_path_is_at_or_under_without_decrypt($game_root, $management_home) || $game_root eq $management_home)
	{
		return (0, "", "Resolved game root escapes the management home.");
	}
	return (1, $game_root, "");
}

# Resolve Start run directories under game_root while accepting Panel's transitional game_key-prefixed run_dir.
sub resolve_game_payload_path_without_decrypt
{
	my ($management_home, $game_key, $relative_path) = @_;
	my ($ok, $game_root, $error) = resolve_game_root_without_decrypt($management_home, $game_key);
	return (0, "", $error) unless($ok);
	$relative_path = "" unless(defined($relative_path));
	$relative_path = normalize_agent_path_without_decrypt($relative_path);
	return (0, "", "Payload path must be relative.") if($relative_path =~ m{^/} || $relative_path =~ /^[A-Za-z]:/);
	return (0, "", "Payload path contains a control character.") if($relative_path =~ /[\x00-\x1F\x7F]/);
	foreach my $segment (split(m{/+}, $relative_path))
	{
		next if($segment eq "");
		return (0, "", "Payload path contains traversal.") if($segment eq "." || $segment eq "..");
	}
	return (1, $game_root, "") if($relative_path eq "" || $relative_path eq ".");

	my $panel_prefixed_path = normalize_agent_path_without_decrypt("$management_home/$relative_path");
	return (1, $panel_prefixed_path, "") if(normalized_path_is_at_or_under_without_decrypt($panel_prefixed_path, $game_root));

	my $game_relative_path = normalize_agent_path_without_decrypt("$game_root/$relative_path");
	return (1, $game_relative_path, "") if(normalized_path_is_at_or_under_without_decrypt($game_relative_path, $game_root));
	return (0, "", "Resolved payload path escapes game root.");
}

sub process_associated_with_home_without_decrypt
{
	my ($pid, $home_path) = @_;
	return 0 unless(defined($home_path) && $home_path ne "" && defined($pid) && $pid =~ /^\d+$/);
	my $abs_home = Cwd::abs_path($home_path);
	return 0 unless(defined($abs_home) && $abs_home ne "");
	foreach my $link ("cwd", "exe")
	{
		my $target = readlink("/proc/$pid/$link");
		if(!defined($target))
		{
			# A game that runs as its own Linux user (gamehomeNNN) hides cwd/exe from the agent user; ask sudo.
			$target = `echo '$SUDOPASSWD'|sudo -kS -p "" readlink /proc/$pid/$link 2>/dev/null`;
			chomp($target) if(defined($target));
			$target = undef if(defined($target) && $target eq "");
		}
		return 1 if(defined($target) && path_is_under_without_decrypt($target, $abs_home));
	}
	my $cmdline = proc_cmdline_without_decrypt($pid);
	return 1 if($cmdline ne "" && index($cmdline, $abs_home) >= 0);
	return 0;
}

sub child_pids_without_decrypt
{
	my ($parent_pid) = @_;
	my @children = ();
	return @children unless(defined($parent_pid) && $parent_pid =~ /^\d+$/);
	opendir(my $PROC, "/proc") or return @children;
	while(my $entry = readdir($PROC))
	{
		next unless($entry =~ /^\d+$/);
		my $ppid = proc_parent_pid_without_decrypt($entry);
		push(@children, $entry) if(defined($ppid) && $ppid eq $parent_pid);
	}
	closedir($PROC);
	return @children;
}

sub process_tree_pids_without_decrypt
{
	my ($root_pid) = @_;
	my @result = ();
	my @queue = ($root_pid);
	my %seen;
	while(@queue)
	{
		my $pid = shift(@queue);
		next unless(defined($pid) && $pid =~ /^\d+$/);
		next if($seen{$pid});
		$seen{$pid} = 1;
		push(@result, $pid);
		push(@queue, child_pids_without_decrypt($pid));
	}
	return @result;
}

# Read the Linux process-group ID from /proc so cleanup can target managed groups.
sub proc_process_group_id_without_decrypt
{
	my ($pid) = @_;
	return "" unless(defined($pid) && $pid =~ /^\d+$/);
	my $stat = read_proc_text_without_decrypt("/proc/$pid/stat");
	return "" unless($stat =~ /\)\s+(.+)$/);
	my @fields = split(/\s+/, $1);
	return "" unless(@fields >= 3 && $fields[2] =~ /^\d+$/);
	return $fields[2];
}

# Return all live PIDs that currently belong to one Linux process group.
sub process_group_pids_without_decrypt
{
	my ($process_group_id) = @_;
	my @group_pids = ();
	return @group_pids unless(defined($process_group_id) && $process_group_id =~ /^\d+$/);
	opendir(my $PROC, "/proc") or return @group_pids;
	while(my $entry = readdir($PROC))
	{
		next unless($entry =~ /^\d+$/);
		push(@group_pids, $entry) if(proc_process_group_id_without_decrypt($entry) eq $process_group_id);
	}
	closedir($PROC);
	return @group_pids;
}

sub kill_pid_with_escalation_without_decrypt
{
	my ($pid, $as_user) = @_;
	return 0 unless(defined($pid) && $pid =~ /^\d+$/);
	# Always signal as root: the game may run as another Linux user, or have no screen session left to ask.
	# Ask nicely first (TERM), then force (KILL) if it is still alive.
	sudo_exec_without_decrypt("kill -15 $pid");
	for(my $i = 0; $i < 10; $i++)
	{
		return 1 unless(is_pid_alive_without_decrypt($pid));
		select(undef, undef, undef, 0.5);
	}
	sudo_exec_without_decrypt("kill -9 $pid");
	sleep 1;
	return is_pid_alive_without_decrypt($pid) ? 0 : 1;
}

sub find_process_pids_by_port_without_decrypt
{
	my ($port, $protocol) = @_;
	return () unless(defined($port) && $port =~ /^\d+$/ && $port > 0 && $port <= 65535);
	$protocol = "any" unless(defined($protocol) && $protocol =~ /^(tcp|udp|any)$/i);
	$protocol = lc($protocol);
	my @commands = ();
	if($protocol eq "tcp" || $protocol eq "any")
	{
		push(@commands, "lsof -nP -t -iTCP:$port -sTCP:LISTEN 2>/dev/null");
		push(@commands, "ss -lntp '( sport = :$port )' 2>/dev/null");
	}
	if($protocol eq "udp" || $protocol eq "any")
	{
		push(@commands, "lsof -nP -t -iUDP:$port 2>/dev/null");
		push(@commands, "ss -lnup '( sport = :$port )' 2>/dev/null");
	}
	my %pids = ();
	# Games run as their own Linux user, so as the agent user lsof/ss cannot see their PIDs. Ask sudo too.
	my @with_sudo = map { "echo '$SUDOPASSWD'|sudo -kS -p \"\" $_" } @commands;
	foreach my $command (@commands, @with_sudo)
	{
		my $out = `$command`;
		next unless(defined($out) && $out ne "");
		while($out =~ /\bpid=([0-9]+)\b/g)
		{
			$pids{$1} = 1 if($1 > 0);
		}
		foreach my $line (split(/\r?\n/, $out))
		{
			$line =~ s/^\s+|\s+$//g;
			$pids{$line} = 1 if($line =~ /^[0-9]+$/ && $line > 0);
		}
	}
	return sort { $a <=> $b } keys %pids;
}

sub find_process_pid_by_port_without_decrypt
{
	my ($port, $protocol) = @_;
	my @pids = find_process_pids_by_port_without_decrypt($port, $protocol);
	return @pids ? $pids[0] : "";
}

sub read_home_pid_targets_without_decrypt
{
	my ($home_path) = @_;
	my @targets = ();
	return @targets unless(defined($home_path) && $home_path ne "");
	foreach my $pid_name ("watchdog.pid", "bot.pid", "game.pid")
	{
		my $pid_file = "$home_path/$pid_name";
		if(open(my $PIDFILE, '<', $pid_file))
		{
			while(my $pid = <$PIDFILE>)
			{
				chomp($pid);
				push(@targets, { pid => $pid, source => $pid_name }) if($pid =~ /^\d+$/);
			}
			close($PIDFILE);
		}
	}
	return @targets;
}

sub kill_pid_tree_with_escalation_without_decrypt
{
	my ($pid, $as_user, $home_path, $source) = @_;
	my %result = ( success => 1, killed => [], remaining => [], failure => "" );
	return \%result unless(defined($pid) && $pid =~ /^\d+$/);
	my $root_is_alive = is_pid_alive_without_decrypt($pid);
	my $process_group_id = $root_is_alive ? proc_process_group_id_without_decrypt($pid) : $pid;
	my @group_pids = $process_group_id eq $pid ? process_group_pids_without_decrypt($process_group_id) : ();
	return \%result unless($root_is_alive || @group_pids);
	if($root_is_alive && process_is_protected_without_decrypt($pid))
	{
		$result{success} = 0;
		$result{failure} = "protected PID $pid from $source";
		return \%result;
	}
	my $pid_is_home_associated = $root_is_alive ? process_associated_with_home_without_decrypt($pid, $home_path) : 0;
	my $group_is_home_associated = 0;
	foreach my $group_pid (@group_pids)
	{
		if(process_associated_with_home_without_decrypt($group_pid, $home_path))
		{
			$group_is_home_associated = 1;
			last;
		}
	}
	if(defined($home_path) && $home_path ne "" && $source ne "screen_session" && !$pid_is_home_associated && !$group_is_home_associated)
	{
		$result{success} = 0;
		$result{failure} = "ambiguous PID $pid from $source is not associated with $home_path";
		return \%result;
	}
	my @tree = $root_is_alive ? reverse(process_tree_pids_without_decrypt($pid)) : ();
	my %candidate;
	foreach my $target_pid (@tree, @group_pids)
	{
		$candidate{$target_pid} = 1 if(defined($target_pid) && $target_pid =~ /^\d+$/);
	}
	my %seen;
	foreach my $target_pid (sort { $b <=> $a } keys %candidate)
	{
		next if($seen{$target_pid});
		$seen{$target_pid} = 1;
		next unless(is_pid_alive_without_decrypt($target_pid));
		if(process_is_protected_without_decrypt($target_pid))
		{
			$result{success} = 0;
			push(@{$result{remaining}}, $target_pid);
			next;
		}
		kill_pid_with_escalation_without_decrypt($target_pid, $as_user);
		push(@{$result{killed}}, $target_pid);
	}
	sleep 1;
	foreach my $target_pid (sort { $b <=> $a } keys %candidate)
	{
		push(@{$result{remaining}}, $target_pid) if(is_pid_alive_without_decrypt($target_pid));
	}
	$result{success} = 0 if(@{$result{remaining}});
	return \%result;
}

sub kill_home_pid_files_without_decrypt
{
	my ($home_path, $as_user) = @_;
	return unless(defined($home_path) && $home_path ne "");
	foreach my $target (read_home_pid_targets_without_decrypt($home_path))
	{
		logger "Attempting forced stop for $target->{source} PID $target->{pid}.";
		kill_pid_tree_with_escalation_without_decrypt($target->{pid}, $as_user, $home_path, $target->{source});
	}
}

sub force_kill_tracked_and_port_without_decrypt
{
	my ($home_id, $server_port, $as_user, $home_path) = @_;
	my $pid_meta = read_pid_metadata($home_id);
	my @tracked_pids = ();
	push(@tracked_pids, $pid_meta->{game_pid}) if(defined($pid_meta->{game_pid}) && $pid_meta->{game_pid} =~ /^\d+$/);
	my %seen;
	foreach my $pid (@tracked_pids)
	{
		next if($seen{$pid});
		$seen{$pid} = 1;
		kill_pid_tree_with_escalation_without_decrypt($pid, $as_user, $home_path, "runtime_status");
	}
	foreach my $port_pid (find_process_pids_by_port_without_decrypt($server_port, "any"))
	{
		next if($seen{$port_pid});
		$seen{$port_pid} = 1;
		next if(process_is_protected_without_decrypt($port_pid));
		next if(defined($home_path) && $home_path ne "" && !process_associated_with_home_without_decrypt($port_pid, $home_path));
		kill_pid_tree_with_escalation_without_decrypt($port_pid, $as_user, $home_path, "port:$server_port");
	}
}

# Build a stable evidence snapshot used by stop verification and structured failures.
sub lifecycle_stop_evidence_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $home_path) = @_;
	my $pid_meta = read_pid_metadata($home_id);
	my @home_targets = read_home_pid_targets_without_decrypt($home_path);
	my @tracked_pids = ();
	foreach my $target (@home_targets)
	{
		push(@tracked_pids, $target->{pid}) if($target->{pid} =~ /^\d+$/);
	}
	push(@tracked_pids, $pid_meta->{game_pid}) if(defined($pid_meta->{game_pid}) && $pid_meta->{game_pid} =~ /^\d+$/);
	push(@tracked_pids, $pid_meta->{screen_pid}) if(defined($pid_meta->{screen_pid}) && $pid_meta->{screen_pid} =~ /^\d+$/);
	my %seen;
	@tracked_pids = grep { !$seen{$_}++ } @tracked_pids;

	my @remaining_pids = grep { is_pid_alive_without_decrypt($_) } @tracked_pids;
	my @port_pids = find_process_pids_by_port_without_decrypt($server_port, "any");
	my $session_running = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;
	return {
		session_running => $session_running,
		process_running => @remaining_pids ? 1 : 0,
		port_listening => (@port_pids || is_port_listening_without_decrypt($server_ip, $server_port, "any")) ? 1 : 0,
		remaining_pids => \@remaining_pids,
		port_pids => \@port_pids,
		tracked_pids => \@tracked_pids
	};
}


sub safe_port_owner_status_without_decrypt
{
	my ($pid, $home_path, $tracked_roots) = @_;
	return "protected" if(process_is_protected_without_decrypt($pid));
	if(ref($tracked_roots) eq 'HASH')
	{
		foreach my $root_pid (keys %$tracked_roots)
		{
			return "safe" if($pid == $root_pid || process_lineage_contains_without_decrypt($pid, $root_pid));
		}
	}
	return "safe" if(process_associated_with_home_without_decrypt($pid, $home_path));
	return "ambiguous";
}

# Shared authoritative hard-stop implementation for Stop, Force Stop, Restart, and Start preflight.
sub hard_stop_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $home_path, %options) = @_;
	my %result = (
		success => 0,
		status => 'cleanup_failed',
		message => '',
		killed_pids => [],
		remaining_pids => [],
		port_pids => [],
		failures => []
	);
	if(!defined($home_id) || $home_id !~ /^[0-9]+$/ || !defined($home_path) || $home_path eq "" || !-d $home_path ||
	   !defined($server_port) || $server_port !~ /^[0-9]+$/ || $server_port < 1 || $server_port > 65535 ||
	   !defined($server_ip) || $server_ip =~ /^\s*$/)
	{
		$result{status} = 'invalid_target';
		$result{message} = 'Invalid lifecycle cleanup target.';
		return \%result;
	}

	if(!write_desired_state_without_decrypt($home_path, "stopped"))
	{
		$result{status} = 'invalid_target';
		$result{message} = "Unable to write stopped desired state in $home_path.";
		return \%result;
	}

	my $startup_file = Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");
	if($options{remove_startup} && -e $startup_file)
	{
		logger "Removing startup flag " . $startup_file . "";
		unlink($startup_file) or logger "Cannot remove the startup flag file $startup_file $!";
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my $as_user = find_user_by_screen_id($screen_id);
	my $managed_screen_pid = get_screen_pid_without_decrypt($home_id);
	cleanup_server_content_hooks_without_decrypt($home_path, $as_user);

	logger "Hard stop targeting HOME ID:$home_id $server_ip:$server_port.";
	sudo_exec_without_decrypt('screen -S '.$screen_id.' -X quit', $as_user);
	sudo_exec_without_decrypt('screen -wipe > /dev/null 2>&1', $as_user);

	my @pid_targets = read_home_pid_targets_without_decrypt($home_path);
	my $pid_meta = read_pid_metadata($home_id);
	push(@pid_targets, { pid => $managed_screen_pid, source => "screen_session" })
		if(defined($managed_screen_pid) && $managed_screen_pid =~ /^\d+$/);
	push(@pid_targets, { pid => $pid_meta->{game_pid}, source => "runtime_status:game_pid" })
		if(defined($pid_meta->{game_pid}) && $pid_meta->{game_pid} =~ /^\d+$/);

	my %tracked_roots = ();
	my %seen_target = ();
	foreach my $target (@pid_targets)
	{
		next unless($target->{pid} =~ /^\d+$/);
		$tracked_roots{$target->{pid}} = 1;
		next if($seen_target{$target->{pid}}++);
		my $kill = kill_pid_tree_with_escalation_without_decrypt($target->{pid}, $as_user, $home_path, $target->{source});
		push(@{$result{killed_pids}}, @{$kill->{killed}});
		if(!$kill->{success})
		{
			push(@{$result{failures}}, $kill->{failure} || "PID $target->{pid} survived cleanup");
		}
	}

	foreach my $port_pid (find_process_pids_by_port_without_decrypt($server_port, "any"))
	{
		my $owner_status = safe_port_owner_status_without_decrypt($port_pid, $home_path, \%tracked_roots);
		if($owner_status eq "protected")
		{
			$result{status} = 'protected_port_owner';
			push(@{$result{failures}}, "Protected process $port_pid owns port $server_port.");
			next;
		}
		if($owner_status eq "ambiguous")
		{
			$result{status} = 'ambiguous_port_owner';
			push(@{$result{failures}}, "Ambiguous process $port_pid owns port $server_port and is not associated with $home_path.");
			next;
		}
		my $kill = kill_pid_tree_with_escalation_without_decrypt($port_pid, $as_user, $home_path, "port:$server_port");
		push(@{$result{killed_pids}}, @{$kill->{killed}});
		push(@{$result{failures}}, $kill->{failure} || "Port owner $port_pid survived cleanup") unless($kill->{success});
	}

	my $evidence;
	for(my $i = 0; $i < 30; $i++)
	{
		$evidence = lifecycle_stop_evidence_without_decrypt($home_id, $server_ip, $server_port, $home_path);
		last if(!$evidence->{session_running} && !$evidence->{process_running} && !$evidence->{port_listening});
		sleep 2;
	}
	$evidence = lifecycle_stop_evidence_without_decrypt($home_id, $server_ip, $server_port, $home_path);
	$result{remaining_pids} = $evidence->{remaining_pids};
	$result{port_pids} = $evidence->{port_pids};

	if(!@{$result{failures}} && !$evidence->{session_running} && !$evidence->{process_running} && !$evidence->{port_listening})
	{
		clear_lifecycle_runtime_files_without_decrypt($home_id, $home_path);
		$result{success} = 1;
		$result{status} = 'STOPPED';
		$result{message} = 'Hard stop verified: screen, watchdog, bot, game, and assigned port are inactive.';
		return \%result;
	}

	$result{status} = 'cleanup_failed' if($result{status} eq 'cleanup_failed' && !@{$result{failures}});
	push(@{$result{failures}}, "screen still active") if($evidence->{session_running});
	push(@{$result{failures}}, "tracked PIDs still active: " . join(',', @{$evidence->{remaining_pids}})) if(@{$evidence->{remaining_pids}});
	push(@{$result{failures}}, "port owners still active: " . join(',', @{$evidence->{port_pids}})) if(@{$evidence->{port_pids}});
	push(@{$result{failures}}, "port $server_port is still listening") if($evidence->{port_listening} && !@{$evidence->{port_pids}});
	$result{message} = join(' ', @{$result{failures}});
	return \%result;
}

sub get_screen_pid_without_decrypt
{
	my ($home_id) = @_;
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my $as_user = find_user_by_screen_id($screen_id);
	my $ret = sudo_exec_without_decrypt('screen -list | grep '.$screen_id, $as_user);
	my ($retval, $enc_out) = split(/;/, $ret, 2);
	return "" if($retval != 1 || !defined($enc_out));
	$enc_out =~ s/\\n//g;
	my $screen_line = decode_base64($enc_out);
	return $1 if($screen_line =~ /([0-9]+)\.$screen_id/);
	return "";
}

sub is_port_listening_without_decrypt
{
	my ($server_ip, $port, $protocol) = @_;
	return 0 unless(defined($port) && $port =~ /^[0-9]+$/ && $port > 0 && $port <= 65535);
	$protocol = "any" unless(defined($protocol) && $protocol =~ /^(tcp|udp|any)$/i);
	$protocol = lc($protocol);
	my @commands = ();
	if($protocol eq "tcp" || $protocol eq "any")
	{
		push(@commands, "ss -lnt 2>/dev/null");
		push(@commands, "netstat -lnt 2>/dev/null");
		push(@commands, "lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null");
	}
	if($protocol eq "udp" || $protocol eq "any")
	{
		push(@commands, "ss -lnu 2>/dev/null");
		push(@commands, "netstat -lnu 2>/dev/null");
		push(@commands, "lsof -nP -iUDP:$port 2>/dev/null");
	}
	foreach my $command (@commands)
	{
		my $out = `$command`;
		next unless(defined($out) && $out ne "");
		return 1 if($out =~ /[:.]$port(\s|$)/);
	}
	return 0;
}

sub add_expected_port
{
	my ($ports, $name, $port, $protocol) = @_;
	return unless(defined($port) && $port =~ /^[0-9]+$/ && $port > 0 && $port <= 65535);
	$protocol = "any" unless(defined($protocol) && $protocol =~ /^(tcp|udp|any)$/i);
	push(@$ports, { name => $name, port => int($port), protocol => lc($protocol) });
}

sub build_expected_ports
{
	my ($server_port, $query_port, $rcon_port) = @_;
	my @expected_ports = ();
	add_expected_port(\@expected_ports, "game", $server_port, "any");
	foreach my $part (split(/[\s,;]+/, $query_port || ""))
	{
		add_expected_port(\@expected_ports, "query", $part, "any");
	}
	foreach my $part (split(/[\s,;]+/, $rcon_port || ""))
	{
		add_expected_port(\@expected_ports, "rcon", $part, "any");
	}
	return @expected_ports;
}

sub validate_expected_ports
{
	my ($server_ip, @expected_ports) = @_;
	my @listening_ports = ();
	my @missing_ports = ();
	foreach my $expected (@expected_ports)
	{
		if(is_port_listening_without_decrypt($server_ip, $expected->{port}, $expected->{protocol}))
		{
			push(@listening_ports, $expected);
		}
		else
		{
			push(@missing_ports, $expected);
		}
	}
	return (\@listening_ports, \@missing_ports);
}

sub has_listening_port_named
{
	my ($ports, $name) = @_;
	foreach my $port (@$ports)
	{
		return 1 if($port->{name} eq $name);
	}
	return 0;
}

sub server_status_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $query_port, $rcon_port, $startup_timeout, $state_hint) = @_;
	return gm_status_reply($home_id);
}

# ---- Game manager (shared with the Windows agent, see GameManager.pm) ----

# Runs a shell command as root, or as $user, with the agent's sudo password.
# Returns ($stdout, '') or ($stdout, $reason) when the command failed.
sub gm_run_as
{
	my ($cmd, $user) = @_;
	$user = 'root' unless(defined($user) && $user ne '');
	(my $q = $cmd) =~ s/'/'\\''/g;
	my $wrapped = $user eq 'root' ? "bash -c '$q'" : "su -s /bin/bash -c '$q' $user";
	(my $pw = defined($SUDOPASSWD) ? $SUDOPASSWD : '') =~ s/'/'\\''/g;
	my ($out, $rc) = GameManagerLinux::qx_rc("echo '$pw' | sudo -kS -p '' $wrapped 2>/dev/null");
	return ($out, $rc == 0 ? '' : "exit $rc");
}

# The Linux user that runs a server's game, and its group. With per-server users on, the user
# gamehome<id> is created the first time it is needed (as before).
sub gm_home_owner
{
	my ($home_id, $create) = @_;
	my $owner = SERVER_RUNNER_USER;
	my $group = SERVER_RUNNER_USER;
	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1")
	{
		$owner = "gamehome" . $home_id;
		$group = `whoami`;
		chomp $group;
		my $userExists = `id -u $owner 2>/dev/null`;
		if($create && not is_integer($userExists))
		{
			logger "User $owner currently doesn't exist... creating user...";
			sudo_exec_without_decrypt("useradd -m $owner");
			sudo_exec_without_decrypt("usermod -s /bin/bash $owner");
			sudo_exec_without_decrypt("usermod -a -G \"$owner\" \"$group\"");
		}
	}
	return ($owner, $group);
}

# The panel can put a server's management home anywhere, so the agent keeps an index:
# homes/<id> holds the folder of server <id>. Written by Start and Stop.
use constant GM_HOMES_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'homes');
our %GM_HOME_DIR;
sub gm_remember_home
{
	my ($home_id, $home_path) = @_;
	return unless(defined($home_id) && $home_id =~ /^\d+$/ && defined($home_path) && $home_path ne '');
	$home_path =~ s{/+$}{};
	mkdir GM_HOMES_DIR unless(-d GM_HOMES_DIR);
	if(open(my $fh, '>', Path::Class::File->new(GM_HOMES_DIR, $home_id)))
	{
		print $fh "$home_path\n";
		close($fh);
	}
	$GM_HOME_DIR{$home_id} = $home_path;
}

sub gm_home_dir
{
	my ($home_id) = @_;
	return $GM_HOME_DIR{$home_id} if(defined($GM_HOME_DIR{$home_id}));
	my $path = '';
	if(open(my $fh, '<', Path::Class::File->new(GM_HOMES_DIR, $home_id)))
	{
		$path = <$fh> // '';
		close($fh);
		chomp $path;
	}
	# No entry yet: a folder that cannot exist, so the server reads as STOPPED.
	$path = Path::Class::Dir->new(GM_HOMES_DIR, "missing-$home_id")->stringify if($path eq '');
	return $GM_HOME_DIR{$home_id} = $path;
}

# Every server in the index, as (id => folder).
sub gm_known_homes
{
	my %homes;
	opendir(my $dh, GM_HOMES_DIR) or return %homes;
	for my $id (grep { /^\d+$/ } readdir($dh))
	{
		delete $GM_HOME_DIR{$id};
		$homes{$id} = gm_home_dir($id);
	}
	closedir($dh);
	return %homes;
}

# Launch for GameManager: runs serverStart.sh (the game) or _alsoRun.sh (the bot) in screen as
# the server's user. The screen title stays SCREEN_HOME_<id>, so the panel's console and log work.
sub gm_launch
{
	my ($command, $workdir, $opt) = @_;
	my $script = $opt ? $opt->{script} : undef;
	return (0, 'launch failed: no script') unless(defined($script) && $script ne '');
	(my $dir = $script) =~ s{/[^/]+$}{};
	my %homes = gm_known_homes();
	my ($home_id) = grep { $homes{$_} eq $dir } keys %homes;
	return (0, "launch failed: $dir is not a known server folder") unless(defined($home_id));
	my $bot = $script =~ m{/_alsoRun\.sh$} ? 1 : 0;
	my ($owner) = gm_home_owner($home_id, 0);
	return GameManagerLinux::launch_screen(
		script => $script,
		user => $owner,
		screen_id => $bot ? create_screen_id("BOT", $home_id) : create_screen_id(SCREEN_TYPE_HOME, $home_id),
		screenrc => SCREENRC_FILE,
		run_dir => AGENT_RUN_DIR,
	);
}

our %GM_WINDOW;     # epoch of the last start/stop per server
sub gm {
	our $GM;
	return $GM if($GM);
	GameManagerLinux::set_runner(\&gm_run_as);
	GameManagerLinux::set_helper(Path::Class::File->new(AGENT_RUN_DIR, 'gm_proc_table.pl')->stringify);
	$GM = GameManager->new(
		state_dir       => GAME_STARTUP_DIR,
		dir_for         => \&gm_home_dir,
		agent_dir       => AGENT_RUN_DIR,
		now             => sub { time() },
		pid_alive       => \&GameManagerLinux::pid_alive,
		pid_executable_matches => \&GameManagerLinux::pid_executable_matches,
		port_listening  => \&GameManagerLinux::port_listening,
		port_owner_pids => \&GameManagerLinux::port_owner_pids,
		pid_path        => \&GameManagerLinux::pid_exe_path,
		child_pids      => \&GameManagerLinux::child_pids,
		kill_pid        => \&GameManagerLinux::kill_pid,
		launch          => \&gm_launch,
		log             => sub { logger($_[0]); },
		startup_timeout => 300,   # 5 minutes from launch; a server's start_timeout overrides it
		restart_limit   => 5,
		restart_window  => 1800,
		# Linux settings (the defaults are Windows).
		script_ext      => '.sh',
		write_script    => \&GameManagerLinux::write_server_script,
		write_admin_script => \&GameManagerLinux::write_admin_script,
		launcher_image  => 'screen',
		shell_images    => ['screen', 'bash', 'sh', 'su', 'sudo', 'setsid'],
		fold_case       => 0,
	);
	return $GM;
}

# The panel only reads the status file: one quick reply, no process or port checks here.
sub gm_status_reply {
	my ($home_id) = @_;
	$home_id =~ s/[^0-9]//g;
	my $st = gm()->read_state($home_id);
	my $s  = $st->{state};
	return {
		status => GameManager::panel_status_for($s), state => $s,
		ready => ($s eq 'RUNNING' && $st->{process_running} && $st->{port_listening} ? 1 : 0),
		process_running => ($st->{process_running} ? 1 : 0),
		session_running => ($st->{session_running} ? 1 : 0),
		game_port_listening => ($st->{port_listening} ? 1 : 0),
		query_port_listening => 0, rcon_port_listening => 0,
		desired_state => $st->{desired}, desired => $st->{desired}, updated_at => ($st->{updated_at} || $st->{ts}),
		reason => $st->{reason}, pid => $st->{pid}, last_error => $st->{reason},
		ip => '', port => '', query_port => '', rcon_port => '', query_info => '',
	};
}

# Scheduler job, every 5 seconds: bring every known server in line with its wanted state.
sub gm_monitor_all {
	my %homes = gm_known_homes();
	for my $id (sort { $a <=> $b } keys %homes)
	{
		next unless(-e "$homes{$id}/status");
		GameManagerLinux::forget_process_table();
		eval { gm()->tick($id); 1 } or logger("Monitor error for HOME ID:$id: $@");
		eval { gm()->ensure_bot($id, GameManagerLinux::read_bot_config("$homes{$id}/_alsoRun.sh"), $homes{$id}); 1 } or logger("Bot monitor error for HOME ID:$id: $@");
	}
}

sub set_desired
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $desired) = decrypt_params(@_);
	return gm()->set_desired($home_id, $desired);
}

# Environment variables and pre-start commands from the game config, and the CPU and priority
# settings, for serverStart.sh. Written at Start, read by every launch (also automatic restarts).
# Steam game servers (Source games such as CS:Source and Garry's Mod) load the Steam client
# library from ~/.steam/sdk32 and ~/.steam/sdk64 of the user that runs them, the same links LinuxGSM
# makes. Without them the server cannot log on to Steam ("dlopen failed ... sdk32/steamclient.so").
# These lines run as the server's user at each start; a game without the library is left alone.
sub gm_steamclient_lines
{
	my ($game_root) = @_;
	my $q32 = GameManagerLinux::sh_quote("$game_root/bin/steamclient.so");
	my $q64 = GameManagerLinux::sh_quote("$game_root/bin/linux64/steamclient.so");
	return (
		'gse_home_dir=$(getent passwd "$(id -un)" | cut -d: -f6)',
		"if [ -r $q32 ]; then mkdir -p \"\$gse_home_dir/.steam/sdk32\" && ln -sfn $q32 \"\$gse_home_dir/.steam/sdk32/steamclient.so\"; fi",
		"if [ -r $q64 ]; then mkdir -p \"\$gse_home_dir/.steam/sdk64\" && ln -sfn $q64 \"\$gse_home_dir/.steam/sdk64/steamclient.so\"; fi",
	);
}

sub gm_write_prestart
{
	my ($home_id, $home_path, $game_root, $game_key, $screen_id, $preStart, $envVars, $prefix) = @_;
	my @lines = ("# Written by the agent at Start: environment, launch prefix and pre-start commands.");
	foreach my $line (split /[\r\n]+/, (defined $envVars ? $envVars : ""))
	{
		$line = replace_Env_Vars($screen_id, $home_id, $game_root, $line, $game_key);
		push @lines, $line if($line ne "");
	}
	push @lines, "GSE_LAUNCH_PREFIX=" . GameManagerLinux::sh_quote($prefix);
	push @lines, gm_steamclient_lines($game_root);
	foreach my $line (split /[\r\n]+/, (defined $preStart ? $preStart : ""))
	{
		$line = replace_Env_Vars($screen_id, $home_id, $game_root, $line, $game_key);
		push @lines, $line if($line ne "");
	}
	# The home is writable by the game user, so never write through a symlink planted there.
	my $prestart = "$home_path/gse_prestart.sh";
	unlink $prestart if(-l $prestart || -e $prestart);
	sysopen(my $fh, $prestart, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0664) or return 0;
	print $fh join("\n", @lines) . "\n";
	close($fh);
	return 1;
}

# Universal startup function
sub universal_start
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return universal_start_without_decrypt(decrypt_params(@_));
}

# Split to two parts because of internal calls.
sub universal_start_without_decrypt
{
	my (
		$home_id, $home_path, $server_exe, $run_dir,
		$startup_cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log
	   ) = @_;
	logger "Start request received for HOME ID:$home_id.";
	$home_path =~ s{/+$}{} if(defined($home_path));

	if (!defined($home_path) || !-d $home_path)
	{
		logger "Can't find server management home [ " . ($home_path // '') . " ].";
		return -10;
	}
	my ($game_root_ok, $game_root, $game_root_error) = resolve_game_root_without_decrypt($home_path, $game_key);
	if(!$game_root_ok)
	{
		logger "Invalid game_key for HOME ID:$home_id at $home_path: $game_root_error";
		return -17;
	}
	if(!-d $game_root)
	{
		logger "Can't find the game folder [ $game_root ] in management home [ $home_path ].";
		return -10;
	}
	my ($payload_path_ok, $game_binary_dir, $payload_path_error) = resolve_game_payload_path_without_decrypt($home_path, $game_key, $run_dir);
	if(!$payload_path_ok)
	{
		logger "Invalid game executable directory for HOME ID:$home_id at $home_path: $payload_path_error";
		return -17;
	}
	if(!-d $game_binary_dir)
	{
		logger "Could not find server binary directory $game_binary_dir.";
		return -12;
	}

	if(container_running_for_home_without_decrypt($home_id))
	{
		logger "HOME ID:$home_id is running in a container; native start refused.";
		return -18;
	}

	my ($owner, $group) = gm_home_owner($home_id, 1);
	my $agentGroup = `whoami`;
	chomp $agentGroup;
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);

	# Fix perms on the GSE agent user's homedir so other users can access owned files within this dir.
	sudo_exec_without_decrypt('chmod -R ug+rwx $( getent passwd "' . $agentGroup . '" | cut -d: -f6 )');
	sudo_exec_without_decrypt('find "$( getent passwd "' . $agentGroup . '" | cut -d: -f6 )" -type d -print0 | xargs -0 chmod o+x');

	# Make the server executable runnable, owned by the server's user and locked (as before).
	my $exe_path = "$game_binary_dir/$server_exe";
	secure_path_without_decrypt('chattr-i', $exe_path);
	set_path_ownership($owner, $group, $home_path, 1);
	if (-e $exe_path && !-x $exe_path && !chmod(0775, $exe_path))
	{
		logger "The $server_exe file is not executable.";
		return -13;
	}
	secure_path_without_decrypt('chattr+i', $exe_path);

	# The game command. The executable comes first (GameManager matches the running game by it);
	# wine, the CPU list and the priority go in GSE_LAUNCH_PREFIX in gse_prestart.sh.
	$startup_cmd = replace_Env_Vars($screen_id, $home_id, $game_root, $startup_cmd, $game_key);
	my $file_extension = lc(substr($server_exe, -4));
	my @prefix;
	push @prefix, "taskset -c $cpu" if(defined($cpu) && $cpu ne '' && $cpu ne 'NA');
	push @prefix, "nice -n $nice" if(defined($nice) && $nice =~ /^\d+$/ && $nice > 0);
	logger "Priority $nice needs root; the game starts at normal priority." if(defined($nice) && $nice =~ /^-\d+$/);
	my $command;
	if($file_extension eq ".jar")
	{
		$command = $startup_cmd;
	}
	else
	{
		push @prefix, "wine" if($file_extension eq ".exe" || $file_extension eq ".bat");
		$command = "\"$exe_path\" $startup_cmd";
	}
	if(!gm_write_prestart($home_id, $home_path, $game_root, $game_key, $screen_id, $preStart, $envVars, join(' ', @prefix)))
	{
		logger "Unable to write gse_prestart.sh in $home_path: $!";
		return -16;
	}
	prepare_server_content_runtime_without_decrypt($home_path);
	backup_home_log($home_id, Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id"), $game_root . "/" . (defined($console_log) ? $console_log : ""));
	set_path_ownership($owner, $group, $home_path, 1);

	# Startup flag: the resource statistics use it to know which executables are servers.
	my $startup_file = Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");
	if (open(my $STARTUP, '>', $startup_file))
	{
		print $STARTUP "$home_id,$home_path,$server_exe,$run_dir,,$server_port,$server_ip,$cpu,$nice,,,$game_key,$console_log";
		close($STARTUP);
	}

	gm_remember_home($home_id, $home_path);
	$GM_WINDOW{$home_id} = time();
	my $gm_result = gm()->start($home_id, command => $command, workdir => $game_binary_dir, port => $server_port);
	logger "Start for HOME ID:$home_id returned " . ($gm_result->{ok} ? "started" : "not started: $gm_result->{reason}") . ".";
	queue_agent_event("server_process_started", "info", {
		home_id => $home_id,
		game_home_path => $home_path,
		game_root => $game_root,
		ip => $server_ip,
		game_port => $server_port,
		screen_session_name => $screen_id,
		tracked_pid => $gm_result->{pid} || "",
		actual_process_state => "starting",
		actual_port_state => "pending_validation",
		message => "Server launched; the game monitor confirms the port within 5 minutes."
	}) if($gm_result->{ok});
	chdir AGENT_RUN_DIR;
	return $gm_result->{ok} ? 1 : -14;
}

# This is used to change the priority of process
# @return 1 if successfully set prosess priority
# @return -1 in case of an error.
sub renice_process
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return renice_process_without_decrypt(decrypt_params(@_));
}

sub renice_process_without_decrypt
{
	my ($home_id, $nice) = @_;
	if ($nice != 0)
	{
		my @pids = get_home_pids($home_id);
		logger
		  "Renicing pids [ @pids ] from home_id $home_id with nice value $nice.";
		foreach my $pid (@pids)
		{
			my $ret = sudo_exec_without_decrypt('/usr/bin/renice '.$nice.' '.$pid);
			($ret) = split(/;/, $ret, 2);
			if($ret != 1)
			{
				logger "Unable to renice process, probably bad sudo password or not in sudoers list.";
				return -1
			}
		}
	}
	return 1;
}

# This is used to force a process to run on a particular CPU
sub force_cpu
{
	return force_cpu_without_decrypt(decrypt_params(@_));
}

sub force_cpu_without_decrypt
{
	my ($home_id, $cpu) = @_;
	if ($cpu ne 'NA')
	{
		my @pids = get_home_pids($home_id);
		logger
		  "Setting server from home_id $home_id with pids @pids to run on CPU $cpu.";
		foreach my $pid (@pids)
		{
			my $rpid = kill 0, $pid;
			if ($rpid == 1)
			{
				my $ret = sudo_exec_without_decrypt('/usr/bin/taskset -pc '.$cpu.' '.$pid);
				($ret) = split(/;/, $ret, 2);
				if($ret != 1)
				{
					logger "Unable to set cpu, probably a bad sudo password or not in sudoers list.";
					return -1
				}
			}
		}
	}
	return 1;
}

# Returns the number of CPUs available.
sub cpu_count
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if (!-e "/proc/cpuinfo")
	{
		return "ERROR - Missing /proc/cpuinfo";
	}

	open(CPUINFO, '<', "/proc/cpuinfo")
	  or return "ERROR - Cannot open /proc/cpuinfo";

	my $cpu_count = 0;

	while (<CPUINFO>)
	{
		chomp;
		next if $_ !~ /^processor/;
		$cpu_count++;
	}
	close(CPUINFO);
	return "$cpu_count";
}

### File exists check ####
# Simple a way to check if a file exists using the remote agent
#
# @return 0 when file exists.
# @return 1 when file does not exist.
sub rfile_exists
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	my $checkFile = decrypt_param(@_);

	if (-e $checkFile)
	{
		return 0;
	}
	else
	{
		return 1;
	}
}

#### Quick check to verify agent is up and running
# Used to quickly see if the agent is online, and if the keys match.
# The message that is sent to the agent must be hello, if not then
# it is intrepret as encryption key missmatch.
#
# @return 1 when encrypted message is not 'hello'
# @return 0 when check is ok.
sub quick_chk
{
	my $dec_check = &decrypt_param(@_);
	if ($dec_check ne 'hello')
	{
		logger "ERROR - Encryption key mismatch! Returning 1 to asker.";
		return 1;
	}
	return 0;
}

# A log may be read only when it is a regular file (not a symlink) whose real path stays
# inside the server's management home or the agent's screen-log folder.
sub log_file_is_safe_without_decrypt
{
	my ($log_file, $home_path) = @_;
	return (0, "log path is empty") unless(defined($log_file) && $log_file ne "");
	return (0, "log path contains a control character") if($log_file =~ /[\x00-\x1f\x7f]/);
	return (0, "log path is a symlink") if(-l $log_file);
	return (0, "log path is not a regular file") unless(-f $log_file);
	my $real = Cwd::abs_path($log_file);
	return (0, "log path cannot be resolved") unless(defined($real) && $real ne "");
	foreach my $root ($home_path, "" . SCREEN_LOGS_DIR)
	{
		next unless(defined($root) && $root ne "");
		my $root_real = Cwd::abs_path($root);
		next unless(defined($root_real) && $root_real ne "" && $root_real ne "/");
		return (1, "") if(index($real, "$root_real/") == 0);
	}
	return (0, "log path is outside the server folder");
}

# Returns the last lines of a log, read as the server's own Linux user so a swapped path
# can only ever reach files that user could already read.
sub read_log_tail_as_owner_without_decrypt
{
	my ($home_id, $log_file, $lines) = @_;
	my ($owner) = gm_home_owner($home_id, 0);
	my $agent_user = `whoami`;
	chomp $agent_user;
	(my $quoted = $log_file) =~ s/'/'\\''/g;
	my $cmd = "tail -n " . (0 + $lines) . " -- '$quoted'";
	my $out;
	if(defined($owner) && $owner ne "" && $owner ne $agent_user && defined(getpwnam($owner)))
	{
		($out) = gm_run_as($cmd, $owner);
	}
	else
	{
		$out = `$cmd 2>/dev/null`;
	}
	$out = "" unless(defined($out));
	return map { "$_\n" } split(/\n/, $out);
}

sub log_path_has_wildcards
{
	my ($path) = @_;
	return defined($path) && $path =~ /[*?\[]/ ? 1 : 0;
}

sub wildcard_pattern_to_regex
{
	my ($pattern) = @_;
	return undef unless defined($pattern);

	my $regex = '';
	my @chars = split(//, $pattern);
	my $in_class = 0;
	for (my $i = 0; $i <= $#chars; $i++)
	{
		my $c = $chars[$i];
		if (!$in_class)
		{
			if ($c eq '*')
			{
				$regex .= '[^/]*';
			}
			elsif ($c eq '?')
			{
				$regex .= '[^/]';
			}
			elsif ($c eq '[')
			{
				$in_class = 1;
				$regex .= '[';
			}
			else
			{
				$regex .= quotemeta($c);
			}
		}
		else
		{
			if ($c eq ']')
			{
				$in_class = 0;
				$regex .= ']';
			}
			else
			{
				$regex .= $c;
			}
		}
	}

	return undef if $in_class;
	return qr/^$regex\z/;
}

sub resolve_latest_log_match
{
	my ($home_path, $pattern) = @_;
	return undef if !defined($home_path) || !defined($pattern) || $pattern eq "";

	$pattern =~ s{\\}{/}g;
	$pattern =~ s{^\./+}{};
	return undef if $pattern =~ /\0/;
	return undef if $pattern =~ m{^/};
	return undef if $pattern =~ m{(^|/)\.\.(?:/|$)};

	my $home_abs = Cwd::abs_path($home_path);
	return undef unless defined($home_abs);
	my $regex = wildcard_pattern_to_regex($pattern);
	return undef unless defined($regex);
	my $glob_pattern = $pattern;
	$glob_pattern =~ s/\[([^\]]+)\]/\*/g;
	# Escape glob characters in the home path so only the log pattern is expanded.
	my $safe_home = $home_abs;
	$safe_home =~ s/([\\*?\[\]{}~])/\\$1/g;
	my @matches = bsd_glob("$safe_home/$glob_pattern", GLOB_NOSORT);
	my @candidates = ();
	foreach my $candidate (@matches)
	{
		next unless -f $candidate;
		my $candidate_abs = Cwd::abs_path($candidate);
		next unless defined($candidate_abs);
		next unless $candidate_abs eq $home_abs || index($candidate_abs, "$home_abs/") == 0;
		my $candidate_rel = $candidate_abs;
		$candidate_rel =~ s{\\}{/}g;
		my $home_norm = $home_abs;
		$home_norm =~ s{\\}{/}g;
		$candidate_rel =~ s/^\Q$home_norm\E\/?//;
		next unless $candidate_rel =~ $regex;
		my $mtime = (stat($candidate_abs))[9] || 0;
		push(@candidates, [ $candidate_abs, $mtime ]);
	}

	return undef unless scalar(@candidates) > 0;
	@candidates = sort { $b->[1] <=> $a->[1] || $b->[0] cmp $a->[0] } @candidates;
	return $candidates[0]->[0];
}

### Return -10 If home path is not found.
### Return -9  If log type was invalid.
### Return -8  If log file was not found.
### 0 reserved for connection problems.
### Return 1;content If log found and screen running.
### Return 2;content If log found but screen is not running.
sub get_log
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($screen_type, $home_id, $home_path, $nb_of_lines, $log_file) = decrypt_params(@_);
	my $log_request_wildcard = 0;

	if (!chdir $home_path)
	{
		logger "Can't change to server's install path [ $home_path ].";
		return -10;
	}

	if (   ($screen_type eq SCREEN_TYPE_UPDATE)
		&& ($screen_type eq SCREEN_TYPE_HOME))
	{
		logger "Invalid screen type '$screen_type'.";
		return -9;
	}

	if(!$log_file)
	{
		my $screen_id = create_screen_id($screen_type, $home_id);
		$log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	}
	else
	{
		if (log_path_has_wildcards($log_file))
		{
			$log_request_wildcard = 1;
			my $resolved_log_file = resolve_latest_log_match($home_path, $log_file);
			if (!defined($resolved_log_file))
			{
				logger "No log files matched wildcard pattern '$log_file' in '$home_path'.";
				return "-8;" . encode("No log files matched pattern: $log_file");
			}
			logger "Wildcard log '$log_file' resolved to '$resolved_log_file'.";
			$log_file = Path::Class::File->new($resolved_log_file);
		}
		else
		{
			$log_file = Path::Class::File->new($home_path, $log_file);
		}
	}

	# The log lives in a folder the customer can write to, so it is never chmod-ed as root,
	# never followed through a symlink and never passed to a shell unquoted.
	$nb_of_lines = 100 unless(defined($nb_of_lines) && $nb_of_lines =~ /^\d+\z/ && $nb_of_lines > 0);
	$nb_of_lines = 5000 if($nb_of_lines > 5000);

	# Regenerate the log file if it doesn't exist
	unless ( -e $log_file || -l $log_file )
	{
		if ($log_request_wildcard)
		{
			logger "Wildcard log file does not resolve to an existing file: " . $log_file;
			return -8;
		}

		if (sysopen(my $newlog, "$log_file", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0664))
		{
			logger "Log file missing, regenerating: " . $log_file;
			print $newlog "Log file missing, started new log\n";
			close($newlog);
		}
		else
		{
			logger "Cannot regenerate log file in " . $log_file . " : $!";
			return -8;
		}
	}

	my ($log_safe, $log_error) = log_file_is_safe_without_decrypt("$log_file", $home_path);
	if(!$log_safe)
	{
		logger "Refusing to read log $log_file for HOME ID:$home_id: $log_error";
		return -8;
	}

	# Return a few lines of output to the web browser, read as the server's own Linux user.
	my(@modedlines) = read_log_tail_as_owner_without_decrypt($home_id, "$log_file", $nb_of_lines);

	# Create local copy of current log file if SCREEN_LOG_LOCAL = 1
	# (only the lines already read; never copied through a symlink).
	if(SCREEN_LOG_LOCAL == 1 && $screen_type eq SCREEN_TYPE_HOME)
	{
		my $log_local = Path::Class::File->new($home_path, "LOG_$screen_type.txt");
		unlink "$log_local" if( -e "$log_local" || -l "$log_local" );
		if (sysopen(my $local_fh, "$log_local", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0664))
		{
			print $local_fh @modedlines;
			close($local_fh);
		}
	}

	my $linecount = 0;

	foreach my $line (@modedlines) {
		#Remove unwanted characters (https://superuser.com/questions/99128/removing-the-escape-characters-from-gnu-screens-screenlog-n)
		$line =~ s/\x1b[[()=][;?0-9]*[0-9A-Za-z]?//g;
		$line =~ s/\r//g;
		$line =~ s/\007//g;
		#Text replacements to remove the Steam user login from steamcmd logs for security reasons.
		$line =~ s/login .*//g;
		$line =~ s/Logging .*//g;
		$line =~ s/set_steam_guard_code.*//g;
		$line =~ s/force_install_dir.*//g;
		#Text replacements to remove empty lines.
		$line =~ s/^ +//g;
		$line =~ s/^\t+//g;
		$line =~ s/^\e+//g;
		#Remove ï¿½ from console output when master server update is running.
		$line =~ s/ï¿½//g;
		$modedlines[$linecount]=$line;
		$linecount++;
	}

	my $encoded_content = encode_list(@modedlines);
	chdir AGENT_RUN_DIR;
	if(is_screen_running_without_decrypt($screen_type, $home_id) == 1
		|| ($screen_type eq SCREEN_TYPE_HOME && container_running_for_home_without_decrypt($home_id)))
	{
		return "1;" . $encoded_content;
	}
	else
	{
		return "2;" . $encoded_content;
	}
}

# stop server function
sub stop_server
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return stop_server_without_decrypt(decrypt_params(@_));
}

##### Stop server without decrypt
### Return 1 when error occurred on decryption.
### Return 0 on success
sub stop_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $home_path) = @_;
	logger "Stop request received for HOME ID:$home_id.";
	gm_remember_home($home_id, $home_path) if(defined($home_path) && -d $home_path);
	$GM_WINDOW{$home_id} = time();
	my $stop = gm()->stop($home_id);
	unlink(Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port")) if(defined($server_ip) && defined($server_port));
	if($stop->{ok})
	{
		queue_agent_event("server_stop_confirmed", "info", {
			home_id => $home_id,
			ip => $server_ip,
			game_port => $server_port,
			actual_process_state => "stopped",
			actual_port_state => "closed",
			message => "Server stopped and its port is free."
		});
		return 0;
	}
	logger "Server $server_ip:$server_port could not be fully stopped: " . ($stop->{reason} || "port $server_port still in use");
	queue_agent_event("server_unresponsive", "error", {
		home_id => $home_id,
		ip => $server_ip,
		game_port => $server_port,
		actual_process_state => "unknown",
		actual_port_state => $stop->{port_open} ? "listening" : "closed",
		message => $stop->{reason} || "Server remained active after stop."
	});
	return 1;
}


sub force_stop_server
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $server_ip, $server_port, $home_path) = decrypt_params(@_);
	return force_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path);
}

sub force_stop_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $home_path) = @_;
	if(!defined($home_id) || $home_id !~ /^[0-9]+$/ || !defined($server_port) || $server_port !~ /^[0-9]+$/ || $server_port < 1 || $server_port > 65535)
	{
		return component_update_response(success => 0, status => 'invalid_target', message => 'Invalid force-stop target.', home_id => $home_id || '', ip => $server_ip || '', port => $server_port || '');
	}

	logger "Force stop requested for HOME ID:$home_id $server_ip:$server_port.";
	# STOPPED is recorded first, or the game monitor would start the game again.
	gm_remember_home($home_id, $home_path) if(defined($home_path) && -d $home_path);
	gm()->stop($home_id);
	my $hard_stop = hard_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path, remove_startup => 1, force => 1);
	my $evidence = lifecycle_stop_evidence_without_decrypt($home_id, $server_ip, $server_port, $home_path);
	my $success = $hard_stop->{success} ? 1 : 0;
	my $message = $success ? 'Force Stop completed. The game server was not restarted.' : 'Force Stop could not fully stop the server. Review remaining process/session/port state.';
	queue_agent_event($success ? "server_force_stop_confirmed" : "server_force_stop_failed", $success ? "warning" : "error", {
		home_id => $home_id,
		ip => $server_ip,
		game_port => $server_port,
		message => $message
	});
	return component_update_response(
		success => $success,
		status => $success ? 'STOPPED' : $hard_stop->{status},
		message => $message,
		home_id => $home_id,
		ip => $server_ip,
		port => $server_port,
		session_running => $evidence->{session_running},
		process_running => $evidence->{process_running},
		port_listening => $evidence->{port_listening},
		attempted_pids => join(',', @{$evidence->{tracked_pids}}),
		killed_pids => join(',', @{$hard_stop->{killed_pids}}),
		remaining_pids => join(',', @{$hard_stop->{remaining_pids}}),
		failure_reason => $hard_stop->{message} || $hard_stop->{status},
		log_hint => AGENT_LOG_FILE
	);
}

##### Send RCON command
### Return 0 when error occurred on decryption.
### Return 1 on success
sub send_rcon_command
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $rconCommand) = decrypt_params(@_);

	# legacy console
	if ($control_protocol eq "lcon")
	{
		my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
		my $as_user = find_user_by_screen_id($screen_id);
		my $ScreenCommand = 'screen -S '.$screen_id.' -p 0 -X stuff "'.$rconCommand.'$(printf \\\\r)"';
		logger "Sending legacy console command to ".$screen_id.": \n$rconCommand \n .";
		my $ret = sudo_exec_without_decrypt($ScreenCommand, $as_user);
		my ($retval, $enc_out) = split(/;/, $ret, 2);
		if($retval == 1)
		{
			my(@modedlines) = "$rconCommand";
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		return 0;
	}

	# Some validation checks for the variables.
	if ($server_ip =~ /^\s*$/ || $server_port < 0 || $server_port > 65535)
	{
		logger("Invalid IP:Port given $server_ip:$server_port.");
		return 0;
	}

	if ($control_password !~ /^\s*$/)
	{
		if ($control_protocol eq "rcon")
		{
			use KKrcon::KKrcon;
			my $rcon = new KKrcon(
								  Password => $control_password,
								  Host	 => $server_ip,
								  Port	 => $server_port,
								  Type	 => $control_type
								 );

			logger "Sending RCON command to $server_ip:$server_port: \n$rconCommand \n  .";

			my(@modedlines) = $rcon->execute($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		elsif ($control_protocol eq "rcon2")
		{
			use KKrcon::HL2;
			my $rcon2 = new HL2(
								  hostname => $server_ip,
								  port	 => $server_port,
								  password => $control_password,
								  timeout  => 2
								 );

			logger "Sending RCON command to $server_ip:$server_port: \n $rconCommand \n  .";

			my(@modedlines) = $rcon2->run($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		elsif ($control_protocol eq "armabe")
		{
			use ArmaBE::ArmaBE;
			my $armabe = new ArmaBE(
								  hostname => $server_ip,
								  port	 => $server_port, # Uses server port for now (Arma 2), Arma 3 BE uses a different, user definable port
								  password => $control_password,
								  timeout  => 2
								 );

			logger "Sending RCON command via ArmaBE module to $server_ip:$server_port: \n $rconCommand \n  .";

			my(@modedlines) = $armabe->run($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
	}
	else
	{
		logger "Control protocol PASSWORD NOT SET.";
		return -10;
	}
}

##### Returns a directory listing
### @return List of directories if everything OK.
### @return 0 If the directory is not found.
### @return -1 If cannot open the directory.
sub dirlist
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($datadir) = &decrypt_param(@_);
	logger "Asked for dirlist of $datadir directory.";
	if (!-d $datadir)
	{
		logger "ERROR - Directory [ $datadir ] not found!";
		return -1;
	}
	if (!opendir(DIR, $datadir))
	{
		logger "ERROR - Can't open $datadir: $!";
		return -2;
	}
	my @dirlist = readdir(DIR);
	closedir(DIR);
	return join(";", @dirlist);
}

##### Returns a directory listing with extra info the filemanager
### @return List of directories if everything OK.
### @return 1 If the directory is empty.
### @return -1 If the directory is not found.
### @return -2 If cannot open the directory.
sub dirlistfm
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $datadir = &decrypt_param(@_);

	logger "Asked for dirlist of $datadir directory.";

	if (!-d $datadir)
	{
		logger "ERROR - Directory [ $datadir ] not found!";
		return -1;
	}

	if (!opendir(DIR, $datadir))
	{
		logger "ERROR - Can't open $datadir: $!";
		return -2;
	}

	my $dir = $datadir;
	$dir =~ s/('+)/'"$1"'/g;
	my $lsattr = `lsattr '$dir' 2>/dev/null`;

	my @attr_all = split /\n+/, $lsattr;

	my %attr = ();

	my ($a, $p, @f);

	foreach (@attr_all)
	{
		($a, $p) = split(/\s/, $_, 2);
		@f = split /\//, $p;
		$attr{$f[-1]}	= $a;
	}

	my %dirfiles = ();

	my (
		$dev,  $ino,   $mode,  $nlink, $uid,	 $gid, $rdev,
		$size, $atime, $mtime, $ctime, $blksize, $blocks
	   );

	my $count = 0;

	chdir($datadir);

	while (my $item = readdir(DIR))
	{
		#skip the . and .. special dirs
		next if $item eq '.';
		next if $item eq '..';
		#print "Dir list is" . $item."\n";
		#Stat the file to get ownership and size
		(
		 $dev,  $ino,   $mode,  $nlink, $uid,	 $gid, $rdev,
		 $size, $atime, $mtime, $ctime, $blksize, $blocks
		) = stat($item);

		if(defined $uid)
		{
			$uid = getpwuid($uid);
		}
		else
		{
			$uid = '';
		}

		if(defined $gid)
		{
			$gid = getgrgid($gid);
		}
		else
		{
			$gid = '';
		}

		#This if else logic determines what it is, File, Directory, other
		if (-T $item)
		{
			# print "File\n";
			$dirfiles{'files'}{$count}{'filename'}	= encode_base64($item);
			$dirfiles{'files'}{$count}{'size'}		= $size;
			$dirfiles{'files'}{$count}{'user'}		= $uid;
			$dirfiles{'files'}{$count}{'group'}		= $gid;
			$dirfiles{'files'}{$count}{'attr'}		= $attr{$item};
		}
		elsif (-d $item)
		{
			# print "Dir\n";
			$dirfiles{'directorys'}{$count}{'filename'}	= encode_base64($item);
			$dirfiles{'directorys'}{$count}{'size'}		= $size;
			$dirfiles{'directorys'}{$count}{'user'}		= $uid;
			$dirfiles{'directorys'}{$count}{'group'}	= $gid;
		}
		elsif (-B $item)
		{
			#print "File\n";
			$dirfiles{'binarys'}{$count}{'filename'}	= encode_base64($item);
			$dirfiles{'binarys'}{$count}{'size'}		= $size;
			$dirfiles{'binarys'}{$count}{'user'}		= $uid;
			$dirfiles{'binarys'}{$count}{'group'}		= $gid;
			$dirfiles{'binarys'}{$count}{'attr'}		= $attr{$item};
		}
		else
		{
			#print "Unknown\n"
			#will be listed as common files;
			$dirfiles{'files'}{$count}{'filename'}	= encode_base64($item);
			$dirfiles{'files'}{$count}{'size'}		= $size;
			$dirfiles{'files'}{$count}{'user'}		= $uid;
			$dirfiles{'files'}{$count}{'group'}		= $gid;
			$dirfiles{'files'}{$count}{'attr'}		= $attr{$item};
		}
		$count++;
	}
	closedir(DIR);

	if ($count eq 0)
	{
		logger "Empty directory $datadir.";
		return 1;
	}

	chdir AGENT_RUN_DIR;
	#Now we return it to the webpage, as array
	return {%dirfiles};
}

###### Returns the contents of a text file
sub readfile
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	my $userfile = &decrypt_param(@_);

	unless ( -e $userfile )
	{
		if (open(BLANK, '>', $userfile))
		{
			close(BLANK);
		}
	}

	if (!open(USERFILE, '<', $userfile))
	{
		logger "ERROR - Can't open file $userfile for reading.";
		return -1;
	}

	my ($wholefile, $buf);

	while (read(USERFILE, $buf, 60 * 57))
	{
		$wholefile .= encode_base64($buf);
	}
	close(USERFILE);

	if(!defined $wholefile)
	{
		return "1; ";
	}

	return "1;" . $wholefile;
}

###### Backs up file, then writes data to new file
### @return 1 On success
### @return 0 In case of a failure
sub writefile
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	# $writefile = file we're editing, $filedata = the contents were writing to it
	my ($writefile, $filedata) = &decrypt_params(@_);
	if (!-e $writefile)
	{
		open FILE, ">", $writefile;
	}
	else
	{
		# backup the existing file
		logger
		  "Backing up file $writefile to $writefile.bak before writing new data.";
		if (!copy("$writefile", "$writefile.bak"))
		{
			logger
			  "ERROR - Failed to backup $writefile to $writefile.bak. Error: $!";
			return 0;
		}
	}
	if (!-w $writefile)
	{
		logger "ERROR - File [ $writefile ] is not writeable!";
		return 0;
	}
	if (!open(WRITER, '>', $writefile))
	{
		logger "ERROR - Failed to open $writefile for writing.";
		return 0;
	}
	$filedata = decode_base64($filedata);
	$filedata =~ s/\r//g;
	print WRITER "$filedata";
	close(WRITER);
	logger "Wrote $writefile successfully!";
	return 1;
}

###### Reboots the server remotely through panel
### @return 1 On success
### @return 0 In case of a failure
sub rebootnow
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	sudo_exec_without_decrypt('sleep 10s; shutdown -r now');
	logger "Scheduled system reboot to occur in 10 seconds successfully!";
	return 1;
}

# Determine the os of the agent machine.
sub what_os
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $which_uname = `which uname`;
	chomp $which_uname;
	if ($which_uname ne "")
	{
		my $os;
		my $os_name;
		my $os_arch;
		my $wine_ver = "";
		$os_name = `$which_uname`;
		chomp $os_name;
		$os_arch = `$which_uname -m`;
		chomp $os_arch;
		my $which_wine = `which wine`;
		chomp $which_wine;
		if ($which_wine ne "")
		{
			$wine_ver = `$which_wine --version`;
			chomp $wine_ver;
			$wine_ver = "|".$wine_ver;
		}
		$os = $os_name." ".$os_arch.$wine_ver;
		return "$os";
	}
	else
	{
		logger "Cannot determine OS..that is odd";
		return "Unknown";
	}
}

### @return PID of the download process if started succesfully.
### @return -1 If could not create temporary download directory.
### @return -2 If could not create destination directory.
### @return -3 If resources unavailable.
sub start_file_download
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($url, $destination, $filename, $action, $post_script) = &decrypt_params(@_);
	logger
	  "Starting to download URL $url. Destination: $destination - Filename: $filename";

	if (!-e $destination)
	{
		logger "Creating destination directory.";
		if (!mkpath $destination )
		{
			logger "Could not create destination '$destination' directory : $!";
			return -2;
		}
	}

	my $download_file_path = Path::Class::File->new($destination, "$filename");

	my $pid = fork();
	if (not defined $pid)
	{
		logger "Could not allocate resources for download.";
		return -3;
	}

	# Only the forked child goes here.
	elsif ($pid == 0)
	{
		my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0,
													SSL_verify_mode => 0x00 } );
		$ua->agent('Mozilla/5.0');
		my $response = $ua->get($url, ':content_file' => "$download_file_path");

		if ($response->is_success)
		{
			logger "Successfully fetched $url and stored it to $download_file_path. Retval: ".$response->status_line;

			if (!-e $download_file_path)
			{
				logger "File $download_file_path does not exist.";
				exit(0);
			}

			if ($action eq "uncompress")
			{
				logger "Starting file uncompress as ordered.";
				uncompress_file_without_decrypt($download_file_path,
												$destination);
			}

			# Run post scripts if any
			if ($post_script ne "")
			{
				logger "Running postscript commands.";
				my @postcmdlines = split /[\r\n]+/, $post_script;
			mkpath(MANUAL_TMP_DIR) unless(-d MANUAL_TMP_DIR);
			my $postcmdfile = Path::Class::File->new(MANUAL_TMP_DIR, "postinstall.$$.".time().".sh");
			my $quoted_destination = shell_single_quote($destination);
			my $quoted_postcmdfile = shell_single_quote($postcmdfile);
			open  FILE, '>', $postcmdfile;
			print FILE "cd $quoted_destination\n";
			foreach my $line (@postcmdlines) {
				logger "Postscript command received \"" . $line ."\".";
				if(handle_lock_command_line($line) == 0){
					print FILE "$line\n";
					}else{
					logger "Lock command completed successfully";
				}
			}
			print FILE "rm -f $quoted_postcmdfile\n";
			close FILE;
			chmod 0755, $postcmdfile;
			my $screen_id = create_screen_id("post_script", $$);
				my $cli_bin = create_screen_cmd($screen_id, "bash $postcmdfile");
				system($cli_bin);
			}
		}
		else
		{
			logger
			  "Unable to fetch $url, or save to $download_file_path. Retval: ".$response->status_line;
			exit(0);
		}

		# Child process must exit.
		exit(0);
	}
	else
	{
		logger "Download process for $download_file_path has pid number $pid.";
		return "$pid";
	}
}

sub lock_additional_files{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($homedir, $files, $action) = &decrypt_params(@_);
	return lock_additional_files_logic($homedir, $files, $action);
}

sub lock_additional_files_logic{
	my ($homedir, $filesToLock, $action, $returnType) = @_;

	logger "Locking additional files specified in the XML.";

	my $commandStr = "";
	$filesToLock = startup_comma_format_to_multiline($filesToLock);
	$filesToLock = replace_Env_Vars("", "", $homedir, $filesToLock);
	my @filesToProcess = split /[\r\n]+/, $filesToLock;
	foreach my $line (@filesToProcess) {
		my $fullPath = $homedir . "/" . $line;
		if($action eq "lock"){
			if(defined $returnType && $returnType eq "str"){
				$commandStr .= "echo '".$SUDOPASSWD."' | sudo -S -p \" \" sh -c \"" . secure_path_without_decrypt("chattr+i", $fullPath, $returnType) . "\" > /dev/null 2>&1" . "\n";
				$commandStr .= "echo '".$SUDOPASSWD."' | sudo -S -p \" \" sh -c \"" . secure_path_without_decrypt("chattr+i", $line, $returnType) . "\" > /dev/null 2>&1" . "\n";
			}else{
				secure_path_without_decrypt("chattr+i", $fullPath);
				secure_path_without_decrypt("chattr+i", $line);
			}
		}else{
			if(defined $returnType && $returnType eq "str"){
				$commandStr .= "echo '".$SUDOPASSWD."' | sudo -S -p \" \" sh -c \"" . secure_path_without_decrypt("chattr-i", $fullPath, $returnType) . "\" > /dev/null 2>&1" . "\n";
				$commandStr .= "echo '".$SUDOPASSWD."' | sudo -S -p \" \" sh -c \"" . secure_path_without_decrypt("chattr-i", $line, $returnType) . "\" > /dev/null 2>&1" . "\n";
			}else{
				secure_path_without_decrypt("chattr-i", $fullPath);
				secure_path_without_decrypt("chattr-i", $line);
			}
		}
	}

	if($commandStr ne ""){
		return $commandStr;
	}

	return "";
}



sub multiline_to_bash_commands{
	my ($multiLineVar) = @_;
	$multiLineVar =~ s/[\n]+/ && /g;
	return $multiLineVar;
}

sub startup_comma_format_to_multiline{
	my ($multiLineVar) = @_;
	$multiLineVar =~ s/{NEWLINE_TOKEN}/\n/g;
	return $multiLineVar;
}

sub create_secure_script
{
	my ($home_path, $exec_folder_path, $exec_path, $management_scripts_path) = @_;
	secure_path_without_decrypt('chattr-i', $home_path);
	$management_scripts_path = $home_path unless(defined($management_scripts_path) && $management_scripts_path ne "");
	mkpath($management_scripts_path) unless(-d $management_scripts_path);
	my $secure = "$management_scripts_path/secure.sh";
	$home_path =~ s/('+)/'\"$1\"'/g;
	$exec_folder_path =~ s/('+)/'\"$1\"'/g;
	$exec_path =~ s/('+)/'\"$1\"'/g;
	my $sec = $secure;
	$sec =~ s/('+)/'\"$1\"'/g;
	open  FILE, '>', $secure;
	print FILE	"chmod 771 '$exec_folder_path'\n".
				"chmod 750 '$exec_path'\n".
				"chmod +x '$exec_path'\n".
				"chattr +i '$exec_path'\n".
				"rm -f '$sec'";
	close FILE;
	chmod 0770, $secure;
	sudo_exec_without_decrypt("chown 0:0 '$sec'");
	return 0;
}

sub check_b4_chdir
{
	my ($path, $owner) = @_;

	if (!-e $path)
	{
		logger "$path does not exist yet. Trying to create it...";

		eval { mkpath($path); 1 } or logger "Error creating $path with Perl mkpath command. Errno: $! - Trying again with sudo...";

		if (!-e $path)
		{
			sudo_exec_without_decrypt('mkdir -p ' . $path);
		}

		if (!-e $path)
		{
			return -1;
		}
	}

	my $group = SERVER_RUNNER_USER;

	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$group = `whoami`;
		chomp $group;
	}

	set_path_ownership($owner, $group, $path);

	if (!chdir $path)
	{
		logger "Unable to change dir to '$path'.";
		return -1;
	}

	return 0;
}

sub set_path_ownership
{
	my ($owner, $group, $path, $skipChattr) = @_;

	my $owner_uid = `id -u $owner`;
	chomp $owner_uid;
	my $group_uid = `id -g $group`;
	chomp $group_uid;

	# Remove immutable flag recursivelly
	if(!$skipChattr){
		secure_path_without_decrypt('chattr-i', $path);
	}

	# Set owner and perms on it recursivelly as well
	my $chownCommand = "chown -Rf $owner_uid:$group_uid '$path'";
	my $chmodCommand = "chmod -Rf ug+rwx '$path'";
	my $chmodCommandDir = "find '$path' -type d -exec chmod o+rx {} +";
	sudo_exec_without_decrypt($chownCommand);
	sudo_exec_without_decrypt($chmodCommand);
	sudo_exec_without_decrypt($chmodCommandDir);

	# find -exec passes names as arguments, so customer file names are never parsed by a root shell.
	my $groupCommand = "find '$path' -type d -exec chmod g+s {} +";
	sudo_exec_without_decrypt($groupCommand);

	$groupCommand = "find '$path' -type d -exec setfacl -d -m u::rwX,g::rwX,o::rx {} +";
	sudo_exec_without_decrypt($groupCommand);

	# Remove perms for other users
	$chmodCommand = "find '$path' -type f -exec chmod o-rwx {} +";
	sudo_exec_without_decrypt($chmodCommand);

	return 0;
}

sub create_bash_scripts
{
	my ( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds ) = @_;

	$home_path         =~ s/('+)/'\"$1\"'/g;
	$bash_scripts_path =~ s/('+)/'\"$1\"'/g;
	my $tmp_secure_script = "$bash_scripts_path/secure.sh";
	my $legacy_secure_script = "$home_path/secure.sh";

	my @precmdlines = split /[\r\n]+/, $precmd;
	my $precmdfile = 'preinstall.sh';
	open  FILE, '>', $precmdfile;
	print FILE "cd '$home_path'\n";
	foreach my $line (@precmdlines) {
		print FILE "$line\n";
	}
	close FILE;
	chmod 0755, $precmdfile;

	my @postcmdlines = split /[\r\n]+/, $postcmd;
	my $postcmdfile = 'postinstall.sh';
	open  FILE, '>', $postcmdfile;
	print FILE "cd '$home_path'\n";
	foreach my $line (@postcmdlines) {
		print FILE "$line\n";
	}
	print FILE "cd '$home_path'\n".
			   "SECURE_SCRIPT='$tmp_secure_script'\n".
			   "if [ ! -f \"\$SECURE_SCRIPT\" ] && [ -f '$legacy_secure_script' ]; then SECURE_SCRIPT='$legacy_secure_script'; fi\n".
			   "if [ -f \"\$SECURE_SCRIPT\" ]; then echo '".$SUDOPASSWD."' | sudo -S -p \" \" bash \"\$SECURE_SCRIPT\"; rm -f \"\$SECURE_SCRIPT\"; fi\n".
			   "cd '$bash_scripts_path'\n".
			   "rm -f preinstall.sh\n".
			   "rm -f postinstall.sh\n".
			   "rm -f runinstall.sh\n";
	close FILE;
	chmod 0755, $postcmdfile;

	my $installfile = 'runinstall.sh';
	open  FILE, '>', $installfile;
	print FILE "#!/bin/bash\n".
			   "cd '$bash_scripts_path'\n".
			   "./$precmdfile\n";
	foreach my $installcmd (@installcmds)
	{
		print FILE "$installcmd\n";
	}
	print FILE "wait ".'${!}'."\n".
			   "cd '$bash_scripts_path'\n".
			   "./$postcmdfile\n";
	close FILE;
	chmod 0755, $installfile;

	return $installfile;
}

#### Run the rsync update ####
### @return 1 If update started
### @return 0 In error case.
sub start_rsync_install
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $home_path, $url, $exec_folder_path, $exec_path, $precmd, $postcmd, $filesToLockUnlock) = decrypt_params(@_);

	my $owner = get_path_owner($home_path);

	if ( check_b4_chdir($home_path, $owner) != 0)
	{
		return 0;
	}

	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;

	if ( check_b4_chdir($bash_scripts_path, $owner) != 0)
	{
		return 0;
	}
	create_secure_script($home_path, $exec_folder_path, $exec_path, $bash_scripts_path);

	# Rsync install require the rsync binary to exist in the system
	# to enable this functionality.
	my $rsync_binary = Path::Class::File->new("/usr/bin", "rsync");

	if (!-f $rsync_binary)
	{
		logger "Failed to start rsync update from "
		  . $url
		  . " to $home_path. Error: Rsync client not installed.";
		return 0;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");

	if(defined $filesToLockUnlock && $filesToLockUnlock ne ""){
		$postcmd .= "\n" . lock_additional_files_logic($home_path, $filesToLockUnlock, "lock", "str");
	}

	backup_home_log( $home_id, $log_file );
	my $path	= $home_path;
	$path		=~ s/('+)/'\"$1\"'/g;
	my @installcmds = ("/usr/bin/rsync --log-file='" . AGENT_RSYNC_GENERIC_LOG . "' --archive --compress --copy-links --update --verbose rsync://$url '$path'");
	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running rsync update: /usr/bin/rsync --log-file='" . AGENT_RSYNC_GENERIC_LOG . "' --archive --compress --copy-links --update --verbose rsync://$url '$home_path'";
	system($screen_cmd);

	chdir AGENT_RUN_DIR;
	return 1;
}

### @return PID of the download process if started succesfully.
### @return -1 If could not create temporary download directory.
### @return -2 If could not create destination directory.
### @return -3 If resources unavailable.
sub master_server_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id,$home_path,$ms_home_id,$ms_home_path,$exec_folder_path,$exec_path,$precmd,$postcmd) = decrypt_params(@_);
	my $owner = get_path_owner($home_path);

	if ( check_b4_chdir($home_path, $owner) != 0)
	{
		return 0;
	}

	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;

	if ( check_b4_chdir($bash_scripts_path, $owner) != 0)
	{
		return 0;
	}
	create_secure_script($home_path, $exec_folder_path, $exec_path, $bash_scripts_path);

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");

	backup_home_log( $home_id, $log_file );

	my $my_home_path = $home_path;
	$my_home_path =~ s/('+)/'\"$1\"'/g;
	$exec_path =~ s/\Q$home_path\E//g;
	$exec_path =~ s/^\///g;
	$exec_path =~ s/('+)/'\"$1\"'/g;
	$ms_home_path =~ s/('+)/'\"$1\"'/g;

	my @installcmds = ("cd '$ms_home_path'");

	## Copy files that match the extensions listed at extPatterns.txt
	open(EXT_PATTERNS, '<', Path::Class::File->new(AGENT_RUN_DIR, "extPatterns.txt"))
		  || logger "Error reading patterns file $!";
	my @ext_paterns = <EXT_PATTERNS>;
	foreach my $patern (@ext_paterns)
	{
		chop $patern;
		push (@installcmds, "find  -iname \\\*.$patern -exec cp -Rfp --parents {} '$my_home_path'/ \\\;");
	}
	close EXT_PATTERNS;

	## Copy the server executable so it can be secured with chattr +i
	push (@installcmds, "cp -vf --parents '$exec_path' '$my_home_path'");

	## Do symlinks for each of the other files
	push (@installcmds, "cp -vuRfs  '$ms_home_path'/* '$my_home_path'");

	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running master server update from home ID $home_id to home ID $ms_home_id";
	system($screen_cmd);

	chdir AGENT_RUN_DIR;
	return 1;
}

sub steam_cmd
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return steam_cmd_without_decrypt(decrypt_params(@_));
}

#### Run the steam client ####
### @return 1 If update started
### @return 0 In error case.
sub steam_cmd_without_decrypt
{
	my ($home_id, $home_path, $mod, $modname, $betaname, $betapwd, $user, $pass, $guard, $exec_folder_path, $exec_path, $precmd, $postcmd, $cfg_os, $filesToLockUnlock, $arch_bits) = @_;
	my $owner = get_path_owner($home_path);

	if ( check_steam_cmd_client() == -1 )
	{
		return 0;
	}

	if ( check_b4_chdir($home_path, $owner) != 0)
	{
		return 0;
	}

	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;

	if ( check_b4_chdir($bash_scripts_path, $owner) != 0)
	{
		return 0;
	}
	create_secure_script($home_path, $exec_folder_path, $exec_path, $bash_scripts_path);

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	my $screen_id_for_txt_update = substr ($screen_id, rindex($screen_id, '_') + 1);
	my $steam_binary = Path::Class::File->new(STEAMCMD_CLIENT_DIR, "steamcmd.sh");
	my $installSteamFile =  $screen_id_for_txt_update . "_install.txt";

	my $installtxt = Path::Class::File->new(STEAMCMD_CLIENT_DIR, $installSteamFile);
	open  FILE, '>', $installtxt;
	print FILE "\@ShutdownOnFailedCommand 1\n";
	print FILE "\@NoPromptForPassword 1\n";
	if($cfg_os eq 'windows')
	{
		print FILE "\@sSteamCmdForcePlatformType windows\n";
	}
	else
	{
		print FILE "\@sSteamCmdForcePlatformType linux\n";
	}

	# Handle requested SteamCMD architecture
	if(defined $arch_bits && $arch_bits ne ""){
		print FILE "\@sSteamCmdForcePlatformBitness " . $arch_bits . "\n";
	}

	if(defined STEAM_DL_LIMIT && STEAM_DL_LIMIT ne "" && is_integer(STEAM_DL_LIMIT) && STEAM_DL_LIMIT > 0){
		print FILE "set_download_throttle " . STEAM_DL_LIMIT . "\n";
	}

	print FILE "force_install_dir \"$home_path\"\n";

	if($guard ne '' && $user ne '' && $user ne 'anonymous')
	{
		print FILE "set_steam_guard_code $guard\n";
	}
	if($user ne '' && $user ne 'anonymous')
	{
		print FILE "login $user $pass\n";
	}
	else
	{
		print FILE "login anonymous\n";
	}

	if($modname ne "")
	{
		print FILE "app_set_config $mod mod $modname\n";
		print FILE "app_update $mod mod $modname validate\n";
	}

	if($betaname ne "" && $betapwd ne "")
	{
		print FILE "app_update $mod -beta $betaname -betapassword $betapwd\n";
	}
	elsif($betaname ne "" && $betapwd eq "")
	{
		print FILE "app_update $mod -beta $betaname\n";
	}
	else
	{
		print FILE "app_update $mod\n";
	}

	print FILE "exit\n";
	close FILE;

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log( $home_id, $log_file );

	my $postcmd_mod = $postcmd;

	if(defined $filesToLockUnlock && $filesToLockUnlock ne ""){
		$postcmd_mod .= "\n" . lock_additional_files_logic($home_path, $filesToLockUnlock, "lock", "str");
	}

	my @installcmds = ("$steam_binary +runscript $installtxt +exit");

	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd_mod, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");

	logger "Running steam update: $steam_binary +runscript $installtxt +exit";
	system($screen_cmd);

	return 1;
}

sub fetch_steam_version
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($appId, $pureOutput) = &decrypt_params(@_);

	if ( check_steam_cmd_client() == -1 )
	{
		return "";
	}

	my $steam_binary = Path::Class::File->new(STEAMCMD_CLIENT_DIR, "steamcmd.sh");
	my $steam_options = "+login anonymous +app_info_update 1 +app_info_print \"$appId\" +quit";
	my $grep = $pureOutput != "0" ? "" : '| grep -EA 1000 "^\s+\"branches\"$" | grep -EA 5 "^\s+\"public\"$" | grep -m 1 -EB 10 "^\s+}$" | grep -E "^\s+\"buildid\"\s+" | tr \'[:blank:]"\' \' \' | tr -s \' \' | cut -d\' \' -f3';

	logger "Getting latest version info for AppId $appId";
	my $response = `$steam_binary $steam_options $grep`;

	return $response;
}

sub installed_steam_version
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($game_home, $mod, $pureOutput) = &decrypt_params(@_);
	my $appFile = $game_home."/steamapps/appmanifest_$mod.acf";
	my $grep = $pureOutput != "0" ? "" : '| grep buildid | tr \'[:blank:]"\' \' \' | tr -s \' \' | cut -d\' \' -f3';

	if ( ! -f $appFile)
	{
		return "-10";
	}

	return `cat $appFile $grep`;
}

sub automatic_steam_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $game_home, $server_ip, $server_port, $exec_path, $exec_folder_path,
		$control_protocol, $control_password, $control_type,
		$appId, $modname, $betaname, $betapwd, $user, $pass, $guard, $precmd, $postcmd, $cfg_os, $filesToLockUnlock,
		$startup_cmd, $cpu, $nice, $preStart, $envVars, $game_key, $arch_bits, $console_log) = &decrypt_params(@_);

	if ( check_steam_cmd_client() == -1 )
	{
		return 0;
	}

	# Is the server currently running? if it is, we'll try to start it after updating.
	my $isServerRunning = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;

	# Check if an update is already happening.
	if (is_screen_running_without_decrypt(SCREEN_TYPE_UPDATE, $home_id) == 1)
	{
		logger("Update already running for server $home_id, unable to start automatic update.");
		return -10;
	}

	# Stop the server if it's running.
	if ($isServerRunning == 1)
	{
		logger("Stopping server $home_id for automatic update.");

		if (stop_server_without_decrypt($home_id, $server_ip, $server_port, $control_protocol, $control_password, $control_type, $game_home) != 0)
		{
			logger("Failed to stop server $home_id for automatic update. Exiting update procedure.");
			return -9
		}

	}

	# steam_cmd: Returns 0 if the update failed, in which case, don't try starting the server - because we may have an incomplete or corrupt installation.
	if (steam_cmd_without_decrypt($home_id, $game_home, $appId, $modname, $betaname, $betapwd, $user, $pass, $guard, $exec_folder_path, $exec_path, $precmd, $postcmd, $cfg_os, $filesToLockUnlock, $arch_bits) == 0)
	{
		logger("Failed to start steam_cmd for server $home_id.");
		return -8;

	} else {

		if ($isServerRunning == 1)
		{
			while (1)
			{
				# If the update screen for $home_id isn't running, attempt to start the server.
				if (is_screen_running_without_decrypt(SCREEN_TYPE_UPDATE, $home_id) == 0)
				{

					if (universal_start_without_decrypt($home_id, $game_home, $exec_path, $exec_folder_path, $startup_cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log) != 1)
					{
						logger("Failed to start server $home_id after automatic update.");
						return -7;
					} else {
						logger("Starting server $home_id after automatic update.");
						return 1;
					}

					last;
				}

				sleep 5;
			}

		} else {
			# Update was started, but server wasn't initially running.
			return 2;
		}

	}

}

sub rsync_progress
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($running_home) = &decrypt_param(@_);
	logger "User requested progress on rsync job on home $running_home.";
	if (-r $running_home)
	{
		$running_home =~ s/('+)/'"$1"'/g;
		my $progress = `du -sk '$running_home'`;
		chomp($progress);
		my ($bytes, $junk) = split(/\s+/, $progress);
		logger("Found $bytes and $junk");
		return $bytes;
	}
	return "0";
}

sub is_file_download_in_progress
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($pid) = &decrypt_param(@_);
	logger "User requested if download is in progress with pid $pid.";
	my @pids = `ps -ef`;
	@pids = grep(/$pid/, @pids);
	logger "Number of pids for file download: @pids";
	if (@pids > '0')
	{
		return 1;
	}
	return 0;
}

### \return 1 If file is uncompressed succesfully.
### \return 0 If file does not exist.
### \return -1 If file could not be uncompressed.
sub uncompress_file
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return uncompress_file_without_decrypt(decrypt_params(@_));
}

sub uncompress_file_without_decrypt
{
	# Globals
	$Archive::Extract::PREFER_BIN = 1;

	# File must include full path.
	my ($file, $destination) = @_;

	logger "Uncompression called for file $file to dir $destination.";

	if (!-e $file)
	{
		logger "File $file could not be found for uncompression.";
		return 0;
	}

	if (!-e $destination)
	{
		mkpath($destination, {error => \my $err});
		if (@$err)
		{
			logger "Failed to create destination dir $destination.";
			return 0;
		}
	}

	my $filesize = (stat($file))[7];

	if($filesize >= 3221225472 && $file =~ /\.zip$/i){
		# Archive::Extract seems to have problems with large zip files, so for files greater than 3GB in size, let the system handle it
		logger "Using system call to unzip.";
		system("unzip -o $file -d $destination");
		if($? != 0){
			logger "Done.";
			return -1;
		}
	}else{

		my $ae = Archive::Extract->new(archive => $file);

		if (!$ae)
		{
			logger "Could not create archive instance for file $file.";
			return -1;
		}

		my $ok = $ae->extract(to => $destination);

		if (!$ok)
		{
			logger "File $file could not be uncompressed.";
			return -1;
		}

		logger "File uncompressed/extracted successfully.";
	}

	return 1;
}

### \return 1 If files are compressed succesfully.
### \return -1 If files could not be compressed.
sub compress_files
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return compress_files_without_decrypt(decrypt_params(@_));
}

sub compress_files_without_decrypt
{
	my ($files,$destination,$archive_name,$archive_type) = @_;

	if (!-e $destination)
	{
		logger "compress_files: Destination path ( $destination ) could not be found.";
		return -1;
	}

	chdir $destination;
	my @items = split /\Q\n/, $files;
	my @inventory;
	if($archive_type eq "zip")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $zip = Archive::Zip->new();
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$zip->addFile( $item );
				}
				elsif (-d $item)
				{
					$zip->addTree( $item, $item );
				}
			}
		}
		# Save the file
		unless ( $zip->writeToFileNamed($archive_name.'.zip') == AZ_OK ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tbz")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				}
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type", COMPRESS_BZIP) ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tgz")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				}
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type", COMPRESS_GZIP) ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tar")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				}
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type") ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "bz2")
	{
		logger $archive_type." compression called.";
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					bzip2 $item => "$item.bz2";
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					foreach my $relative_item (@inventory) {
						bzip2 $relative_item => "$relative_item.bz2";
					}
				}
			}
		}
		logger $archive_type." archives created successfully at $destination";
		return 1;
	}
}

sub discover_ips
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($check) = decrypt_params(@_);

	if ($check ne "chk")
	{
		logger "Invalid parameter '$check' given for discover_ips function.";
		return "";
	}

	# Every IPv4 address players can reach a game on ("ip" works on every supported system; the
	# old ifconfig parsing found nothing on current Ubuntu and Debian). Loopback and virtual
	# interfaces are left out: VPN tunnels (WireGuard wg*, tun*, tap*, Tailscale, ZeroTier) and
	# container or VM bridges (docker*, br-*, veth*, virbr*, lxcbr*, gse*). The panel offers every
	# address returned here for game servers, so a VPN address here meant games bound to it.
	my @ips;
	foreach my $line (`ip -o -4 addr show 2>/dev/null`)
	{
		next unless ($line =~ /^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)\//);
		my ($interface, $ip) = ($1, $2);
		next if ($ip =~ /^127\./);
		next if ($interface =~ /^(lo|wg|tun|tap|tailscale|zt|docker|br-|veth|virbr|lxcbr|gse)/);
		push @ips, $ip;
	}
	logger "Found IPs: @ips";
	return join(",", @ips);
}

# ---------------------------------------------------------------------------
# status_sample: one reading for the panel's status history (modules/status_history/README.md).
# Machine totals are cumulative counters: the panel works out rates and percentages from the change
# between samples. Per-process CPU is measured here over a one-second window and is a share of
# the whole machine (all cores), so it is comparable across hosts.
# ---------------------------------------------------------------------------
sub status_read_cpu_totals
{
	my ($total, $idle, $cores) = (0, 0, 0);
	open(my $fh, '<', '/proc/stat') or return (0, 0, 0);
	while (my $line = <$fh>)
	{
		if ($line =~ /^cpu\s+(.*)$/)
		{
			my @f = split /\s+/, $1;
			my $last = $#f < 7 ? $#f : 7;
			foreach my $i (0 .. $last) { $total += $f[$i] || 0; }
			$idle = ($f[3] || 0) + ($f[4] || 0);
		}
		elsif ($line =~ /^cpu\d+\s/)
		{
			$cores++;
		}
	}
	close($fh);
	return ($total, $idle, $cores);
}

sub status_read_proc_ticks
{
	my (%ticks, %name, %parent);
	opendir(my $dh, '/proc') or return (\%ticks, \%name, \%parent);
	foreach my $pid (grep { /^\d+$/ } readdir($dh))
	{
		open(my $fh, '<', "/proc/$pid/stat") or next;
		my $line = <$fh>;
		close($fh);
		next unless (defined $line && $line =~ /^\d+ \((.*)\)/);
		my $comm = $1;
		my $rest = substr($line, rindex($line, ')') + 2);
		my @f = split /\s+/, $rest;
		# Fields after the closing bracket start at field 3 of stat, so utime (14) is index 11 and stime (15) is index 12.
		$ticks{$pid}  = ($f[11] || 0) + ($f[12] || 0);
		$name{$pid}   = $comm;
		# ppid is field 4 of stat, index 1 here.
		$parent{$pid} = ($f[1] || 0) + 0;
	}
	closedir($dh);
	return (\%ticks, \%name, \%parent);
}

sub status_read_proc_rss
{
	my %rss;
	opendir(my $dh, '/proc') or return \%rss;
	foreach my $pid (grep { /^\d+$/ } readdir($dh))
	{
		open(my $fh, '<', "/proc/$pid/status") or next;
		while (my $line = <$fh>)
		{
			if ($line =~ /^VmRSS:\s+(\d+)\s+kB/) { $rss{$pid} = $1 * 1024; last; }
		}
		close($fh);
	}
	closedir($dh);
	return \%rss;
}

sub status_top_five
{
	my ($hash, $name, $scale) = @_;
	my @rows = sort { $b->[1] <=> $a->[1] } grep { $_->[1] > 0 } map { [$_, $hash->{$_}] } keys %$hash;
	my @out;
	foreach my $row (@rows[0 .. ($#rows < 4 ? $#rows : 4)])
	{
		last unless defined $row;
		my $pid = $row->[0];
		my $label = $name->{$pid} // '?';
		$label =~ s/[|\r\n]//g;
		push @out, sprintf("%d|%s|%s", $pid, substr($label, 0, 60), $scale ? sprintf("%.2f", $row->[1] * $scale) : $row->[1]);
	}
	return @out;
}

sub status_sample
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($status_sample) = decrypt_params(@_);
	if (!defined $status_sample || $status_sample ne "status_sample")
	{
		logger("Invalid parameter '" . ($status_sample // '') . "' given for status_sample function.");
		return -1;
	}

	require Time::HiRes;
	my ($total1, $idle1, $cores) = status_read_cpu_totals();
	my ($ticks1, $name1) = status_read_proc_ticks();
	Time::HiRes::usleep(1000000);
	my ($total2, $idle2, $cores2) = status_read_cpu_totals();
	my ($ticks2, $name2, $parent2) = status_read_proc_ticks();
	my $window = $total2 - $total1;

	# Per-process CPU: share of the whole machine over the window.
	my %cpu_delta;
	if ($window > 0)
	{
		foreach my $pid (keys %$ticks2)
		{
			next unless exists $ticks1->{$pid};
			my $d = $ticks2->{$pid} - $ticks1->{$pid};
			$cpu_delta{$pid} = $d if $d > 0;
		}
	}
	my $cpu_scale = $window > 0 ? 100 / $window : 0;
	my $rss = status_read_proc_rss();
	my @top_cpu = status_top_five(\%cpu_delta, $name2, $cpu_scale);
	my @top_ram = status_top_five($rss, $name2, 0);
	my %containers = status_container_usage(\%cpu_delta, $cpu_scale, $rss, $name2);
	my @homes = status_home_lines(\%cpu_delta, $cpu_scale, $rss, $parent2, \%containers);
	my @container_lines = status_container_lines(\%containers);

	my $uptime = 0;
	if (open(my $fh, '<', '/proc/uptime')) { my $l = <$fh>; close($fh); $uptime = int(($l // '0') =~ /^(\d+)/ ? $1 : 0); }
	my $load1 = 0;
	if (open(my $fh, '<', '/proc/loadavg')) { my $l = <$fh>; close($fh); $load1 = ($l // '0') =~ /^(\S+)/ ? $1 : 0; }

	my ($rx, $tx) = (0, 0);
	if (open(my $fh, '<', '/proc/net/dev'))
	{
		while (my $line = <$fh>)
		{
			next unless ($line =~ /^\s*([^:]+):\s*(.*)$/);
			my ($if, $rest) = ($1, $2);
			next if $if eq 'lo';
			my @f = split /\s+/, $rest;
			$rx += $f[0] || 0;
			$tx += $f[8] || 0;
		}
		close($fh);
	}

	my %mem;
	if (open(my $fh, '<', '/proc/meminfo'))
	{
		while (my $line = <$fh>) { $mem{$1} = $2 if ($line =~ /^(\w+):\s+(\d+)\s+kB/); }
		close($fh);
	}
	my $mem_total = ($mem{MemTotal} || 0) * 1024;
	my $mem_avail = defined $mem{MemAvailable}
		? $mem{MemAvailable} * 1024
		: (($mem{MemFree} || 0) + ($mem{Buffers} || 0) + ($mem{Cached} || 0)) * 1024;
	my $mem_used = $mem_total - $mem_avail;
	$mem_used = 0 if $mem_used < 0;

	my ($disk_total, $disk_used) = (0, 0);
	my @df = `df -P -B1 / 2>/dev/null`;
	if (@df >= 2)
	{
		my @f = split /\s+/, $df[1];
		($disk_total, $disk_used) = ($f[1] || 0, $f[2] || 0);
	}

	my $out = "1;\n";
	$out .= "cores=" . ($cores2 || $cores) . "\n";
	$out .= "uptime=$uptime\n";
	$out .= "load1=$load1\n";
	$out .= "cpu_total=$total2\n";
	$out .= "cpu_idle=$idle2\n";
	$out .= "net_rx=$rx\n";
	$out .= "net_tx=$tx\n";
	$out .= "mem_total=$mem_total\n";
	$out .= "mem_used=$mem_used\n";
	$out .= "disk_total=$disk_total\n";
	$out .= "disk_used=$disk_used\n";
	for my $i (1 .. scalar(@top_cpu)) { $out .= "proc_cpu.$i=$top_cpu[$i - 1]\n"; }
	for my $i (1 .. scalar(@top_ram)) { $out .= "proc_ram.$i=$top_ram[$i - 1]\n"; }
	$out .= "$_\n" foreach (@homes, @container_lines);
	return $out;
}

# One line per game server with a status file:
#   home.<id>=<state>|<cpu percent of the machine>|<RAM bytes>|<disk bytes>|<when the disk was measured>
# CPU and RAM add up the game process and the bot with all their child processes, and the
# server's own container (gse-h<id>-a<allocation>) when it runs in Docker.
sub status_home_lines
{
	my ($cpu_delta, $cpu_scale, $rss, $parent, $containers) = @_;
	my %homes = gm_known_homes();
	my @lines;
	foreach my $id (sort { $a <=> $b } keys %homes)
	{
		next unless (-e "$homes{$id}/status");
		my $state = gm()->read_state($id);
		my $bot = gm()->read_state("$id-bot");
		my @pids = (status_pid_tree($state->{pid}, $rss, $parent), status_pid_tree($bot->{pid}, $rss, $parent));
		my ($cpu, $ram) = (0, 0);
		foreach my $pid (@pids)
		{
			$cpu += ($cpu_delta->{$pid} || 0) * $cpu_scale;
			$ram += $rss->{$pid} || 0;
		}
		foreach my $c (values %$containers)
		{
			next unless (defined $c->{home_id} && $c->{home_id} == $id);
			$cpu += $c->{cpu};
			$ram += $c->{ram};
		}
		my ($disk, $disk_at) = status_home_disk($homes{$id});
		push @lines, sprintf("home.%d=%s|%.2f|%d|%s|%s", $id, $state->{state}, $cpu, $ram, $disk, $disk_at);
	}
	return @lines;
}

# A process and all its children, only if the process is running now. Empty for a stopped server.
sub status_pid_tree
{
	my ($root, $rss, $parent) = @_;
	return () unless (defined $root && $root =~ /^\d+$/ && $root > 0 && exists $parent->{$root});
	my @tree = ($root);
	for (my $i = 0; $i < @tree; $i++)
	{
		my $pid = $tree[$i];
		push @tree, grep { $parent->{$_} == $pid && $_ != $pid } keys %$parent;
	}
	return @tree;
}

# Size of a game server folder, from the disk-usage file in it ("<epoch> <bytes>").
# Measuring a big folder takes a while, so it runs in the background at most once an hour
# and this returns the last result. Empty values until the first measurement is done.
sub status_home_disk
{
	my ($home_dir) = @_;
	my $cache = "$home_dir/disk-usage";
	my ($at, $bytes) = ('', '');
	if (open(my $fh, '<', $cache))
	{
		my $line = <$fh>;
		close($fh);
		($at, $bytes) = ($1, $2) if (defined $line && $line =~ /^(\d+) (\d+)/);
	}
	my $running = "$cache.running";
	my $busy = -e $running && (time() - (stat($running))[9]) < 3600;
	if (!$busy && ($at eq '' || time() - $at >= 3600))
	{
		system("touch '$running' && ( b=\$(du -sb '$home_dir' 2>/dev/null | cut -f1); [ -n \"\$b\" ] && echo \"\$(date +%s) \$b\" > '$cache'; rm -f '$running' ) >/dev/null 2>&1 &");
	}
	return ($bytes, $at);
}

# CPU and RAM of every running Docker container, found from each process's cgroup
# (".../docker-<id>.scope" or ".../docker/<id>"), so it needs no docker command per process.
# Returns container id => { name, image, cpu, ram, process (the process using the most RAM), home_id }.
sub status_container_usage
{
	my ($cpu_delta, $cpu_scale, $rss, $name) = @_;
	my %by_id;
	foreach my $pid (keys %$rss)
	{
		open(my $fh, '<', "/proc/$pid/cgroup") or next;
		my $cgroup = do { local $/; <$fh> };
		close($fh);
		next unless (defined $cgroup && $cgroup =~ m{/docker[-/]([0-9a-f]{12,64})(?:\.scope)?\s*$}m);
		my $c = $by_id{$1} ||= { cpu => 0, ram => 0, top_ram => -1, process => '' };
		$c->{cpu} += ($cpu_delta->{$pid} || 0) * $cpu_scale;
		$c->{ram} += $rss->{$pid} || 0;
		if (($rss->{$pid} || 0) > $c->{top_ram})
		{
			$c->{top_ram} = $rss->{$pid} || 0;
			$c->{process} = defined $name->{$pid} ? $name->{$pid} : '';
		}
	}
	return %by_id unless (%by_id);
	foreach my $line (`docker ps --no-trunc --format '{{.ID}}|{{.Names}}|{{.Image}}' 2>/dev/null`)
	{
		chomp($line);
		my ($id, $cname, $image) = split(/\|/, $line, 3);
		next unless (defined $image && $by_id{$id});
		$by_id{$id}{name} = $cname;
		$by_id{$id}{image} = $image;
		$by_id{$id}{home_id} = $1 if ($cname =~ /^gse-h(\d+)-a\d+$/);
	}
	return %by_id;
}

# One line per container that is not a game server's own container:
#   container.<n>=<name>|<image>|<cpu percent of the machine>|<RAM bytes>|<main process>
sub status_container_lines
{
	my ($containers) = @_;
	my @lines;
	my $n = 0;
	foreach my $id (sort keys %$containers)
	{
		my $c = $containers->{$id};
		next if (defined $c->{home_id});
		my @text = map { my $v = defined $_ ? $_ : ''; $v =~ s/[|\r\n]//g; substr($v, 0, 60) } ($c->{name} // substr($id, 0, 12), $c->{image}, $c->{process});
		$n++;
		push @lines, sprintf("container.%d=%s|%s|%.2f|%d|%s", $n, $text[0], $text[1], $c->{cpu}, $c->{ram}, $text[2]);
	}
	return @lines;
}

### Return -1 In case of invalid param
### Return 1;content in case of success
sub mon_stats
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($mon_stats) = decrypt_params(@_);
	if ($mon_stats ne "mon_stats")
	{
		logger "Invalid parameter '$mon_stats' given for $mon_stats function.";
		return -1;
	}

	# Collect all resource statistics
	logger "Collecting resource usage statistics...";

	# Get CPU usage
	my %cpu_data;
	my %prev_idle;
	my %prev_total;
	open(STAT, '/proc/stat');
	while (<STAT>) {
		next unless /^cpu([0-9]+)/;
		my @stat = split /\s+/, $_;
		$prev_idle{$1} = $stat[4];
		$prev_total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
	}
	close STAT;
	sleep 1;
	my %idle;
	my %total;
	open(STAT, '/proc/stat');
	while (<STAT>) {
		next unless /^cpu([0-9]+)/;
		my @stat = split /\s+/, $_;
		$idle{$1} = $stat[4];
		$total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
	}
	close STAT;
	my $total_cpu_usage = 0;
	my $cpu_core_count = 0;
	foreach my $key ( keys %idle )
	{
		my $diff_idle = $idle{$key} - $prev_idle{$key};
		my $diff_total = $total{$key} - $prev_total{$key};
		my $percent = (100 * ($diff_total - $diff_idle)) / $diff_total;
		$percent = sprintf "%.2f", $percent unless $percent == 0;
		$total_cpu_usage += $percent;
		$cpu_core_count++;
	}
	my $avg_cpu_usage = $cpu_core_count > 0 ? sprintf("%.2f", $total_cpu_usage / $cpu_core_count) : 0;

	# Get RAM usage
	my($mem_total, $buffers, $cached, $mem_free) = qw(0 0 0 0);
	open(STAT, '/proc/meminfo');
	while (<STAT>) {
		$mem_total   += $1 if /MemTotal\:\s+(\d+) kB/;
		$buffers += $1 if /Buffers\:\s+(\d+) kB/;
		$cached  += $1 if /Cached\:\s+(\d+) kB/;
		$mem_free    += $1 if /MemFree\:\s+(\d+) kB/;
	}
	close STAT;
	my $mem_used = $mem_total - $mem_free - $cached - $buffers;
	my $mem_percent = $mem_total > 0 ? sprintf("%.2f", 100 * $mem_used / $mem_total) : 0;
	$mem_total *= 1024; # Convert to bytes
	$mem_used *= 1024;  # Convert to bytes

	# Get disk usage
	my($disk_total, $disk_used, $disk_free) = split(' ', `df -lP 2>/dev/null|grep "^/dev/.*"|awk '{total+=\$2}{used+=\$3}{free+=\$4} END {print total, used, free}'`);
	my $disk_percent = $disk_total > 0 ? sprintf("%.2f", 100 * $disk_used / $disk_total) : 0;
	$disk_total *= 1024; # Convert to bytes
	$disk_used *= 1024;  # Convert to bytes
	$disk_free *= 1024;  # Convert to bytes

	# Get uptime
	open(STAT, '/proc/uptime');
	my $uptime = 0;
	while (<STAT>) {
		$uptime += $1 if /^([0-9]+)/;
	}
	close STAT;

	# Get load average
	my $load_avg_1min = "0";
	my $load_avg_5min = "0";
	my $load_avg_15min = "0";
	open(LOADAVG, '/proc/loadavg');
	while (<LOADAVG>) {
		if (/^(\S+)\s+(\S+)\s+(\S+)/) {
			$load_avg_1min = $1;
			$load_avg_5min = $2;
			$load_avg_15min = $3;
		}
	}
	close LOADAVG;

	# Log the collected statistics
	logger "Resource stats collected - CPU: ${avg_cpu_usage}%, Memory: ${mem_percent}% (${mem_used}/${mem_total} bytes), Disk: ${disk_percent}% (${disk_used}/${disk_total} bytes), Uptime: ${uptime}s, Load: ${load_avg_1min}/${load_avg_5min}/${load_avg_15min}";

	# Submit to database if configured
	my $submit_result = submit_resource_stats_to_db($avg_cpu_usage, $mem_used, $mem_total, $mem_percent, $disk_used, $disk_total, $disk_free, $disk_percent, $uptime, $load_avg_1min, $load_avg_5min, $load_avg_15min);

	if ($submit_result == 1) {
		logger "Resource statistics successfully submitted to MySQL database.";
	} elsif ($submit_result == -1) {
		logger "Failed to submit resource statistics to MySQL database - database not configured.";
	} else {
		logger "Failed to submit resource statistics to MySQL database - error occurred.";
	}

	# Return basic format for compatibility
	my @disk			= `df -hP -x tmpfs`;
	my $encoded_content = encode_list(@disk);
	my @uptime_compat			= `uptime`;
	$encoded_content   .= encode_list(@uptime_compat);
	return "1;$encoded_content";
}

sub ensure_dbi_available
{
	eval {
		require DBI;
		DBI->import();
		1;
	} and return 1;

	my $error = $@ || "unknown error";
	logger "DBI Perl module unavailable; resource stats database submission is disabled: $error";
	scheduler_log_events("DBI Perl module unavailable; resource stats database submission is disabled");
	return 0;
}

sub submit_resource_stats_to_db
{
	my ($cpu_usage, $mem_used, $mem_total, $mem_percent, $disk_used, $disk_total, $disk_free, $disk_percent, $uptime, $load_1min, $load_5min, $load_15min) = @_;

	# Check if database is configured
	if (!defined STATS_DB_HOST || STATS_DB_HOST eq '' ||
		!defined STATS_DB_USER || STATS_DB_USER eq '' ||
		!defined STATS_DB_PASS || STATS_DB_PASS eq '' || STATS_DB_PASS eq 'REPLACE_ME' ||
		!defined STATS_DB_NAME || STATS_DB_NAME eq '') {
		logger "Resource stats database not configured - skipping database submission.";
		scheduler_log_events("Resource stats database not configured - skipping submission");
		return -1;
	}

	if (!ensure_dbi_available()) {
		return -1;
	}

	my $dbh;
	eval {
		# Connect to MySQL database
		my $dsn = "DBI:mysql:database=" . STATS_DB_NAME . ";host=" . STATS_DB_HOST;
		logger "Attempting to connect to MySQL database: $dsn (user: " . STATS_DB_USER . ")";
		$dbh = DBI->connect($dsn, STATS_DB_USER, STATS_DB_PASS, {
			RaiseError => 1,
			AutoCommit => 1,
			mysql_enable_utf8 => 1
		});

		if (!$dbh) {
			logger "Failed to connect to MySQL database: $DBI::errstr";
			return 0;
		}

		logger "Successfully connected to MySQL database for resource stats submission.";

		# Create the proper database tables based on the schema files
		create_resource_stats_tables($dbh);

		# Get machine information
		my $machine_id = get_machine_id();
		my $hostname = `hostname -f 2>/dev/null || hostname`;
		chomp($hostname);
		my $ip = get_local_ip();

		# Ensure the machine is registered
		ensure_machine_registered($dbh, $machine_id, $hostname, $ip);

		# Get additional system metrics for proper schema compliance
		my ($swap_used, $swap_total, $disk_path, $net_iface, $rx_bytes, $tx_bytes, $iface_speed) = get_extended_system_metrics();

		# Insert machine-level resource sample
		insert_machine_sample($dbh, $machine_id, $cpu_usage, $mem_used, $mem_total, $mem_percent,
		                     $swap_used, $swap_total, $disk_path, $disk_total, $disk_used, $disk_percent,
		                     $net_iface, $rx_bytes, $tx_bytes, $iface_speed, $load_1min, $load_5min, $load_15min);

		# Collect and insert per-process/server resource samples
		collect_and_insert_process_samples($dbh, $machine_id);

		$dbh->disconnect();

		logger "Resource statistics inserted into database successfully.";
		return 1;
	};

	if ($@) {
		logger "Error submitting resource stats to database: $@";
		if ($dbh) {
			$dbh->disconnect();
		}
		return 0;
	}

	return 1;
}

sub create_resource_stats_tables
{
	my ($dbh) = @_;
	my $table_prefix = STATS_TABLE_PREFIX || '';

	# Create agent_machines table
	my $machines_sql = qq{
		CREATE TABLE IF NOT EXISTS `${table_prefix}machines` (
			`id` int(11) NOT NULL AUTO_INCREMENT,
			`machine_id` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL,
			`hostname` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
			`ip` varchar(45) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
			`created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (`id`),
			UNIQUE KEY `uniq_machine` (`machine_id`)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
	};

	# Create machine_samples table
	my $machine_samples_sql = qq{
		CREATE TABLE IF NOT EXISTS `${table_prefix}machine_samples` (
			`id` bigint(20) NOT NULL AUTO_INCREMENT,
			`machine_id` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL,
			`ts` datetime NOT NULL,
			`load1` decimal(6,2) DEFAULT NULL,
			`load5` decimal(6,2) DEFAULT NULL,
			`load15` decimal(6,2) DEFAULT NULL,
			`cpu_pct` decimal(6,2) DEFAULT NULL,
			`mem_used_bytes` bigint(20) DEFAULT NULL,
			`mem_total_bytes` bigint(20) DEFAULT NULL,
			`mem_used_pct` decimal(6,2) DEFAULT NULL,
			`swap_used_bytes` bigint(20) DEFAULT NULL,
			`swap_total_bytes` bigint(20) DEFAULT NULL,
			`disk_path` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
			`disk_total_bytes` bigint(20) DEFAULT NULL,
			`disk_used_bytes` bigint(20) DEFAULT NULL,
			`disk_used_pct` decimal(6,2) DEFAULT NULL,
			`net_iface` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
			`rx_bytes` bigint(20) DEFAULT NULL,
			`tx_bytes` bigint(20) DEFAULT NULL,
			`iface_speed_mbps` int(11) DEFAULT NULL,
			PRIMARY KEY (`id`),
			KEY `idx_machine_ts` (`machine_id`,`ts`),
			KEY `idx_ts` (`ts`)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
	};

	# Create process_samples table
	my $process_samples_sql = qq{
		CREATE TABLE IF NOT EXISTS `${table_prefix}process_samples` (
			`id` bigint(20) NOT NULL AUTO_INCREMENT,
			`machine_id` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL,
			`ts` datetime NOT NULL,
			`server_name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
			`server_path` varchar(512) COLLATE utf8mb4_unicode_ci NOT NULL,
			`pid` int(11) NOT NULL,
			`proc_name` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
			`cmd` text COLLATE utf8mb4_unicode_ci,
			`cpu_pct` decimal(7,2) DEFAULT NULL,
			`rss_bytes` bigint(20) DEFAULT NULL,
			`vms_bytes` bigint(20) DEFAULT NULL,
			`mem_pct` decimal(6,2) DEFAULT NULL,
			`io_read_bytes` bigint(20) DEFAULT NULL,
			`io_write_bytes` bigint(20) DEFAULT NULL,
			`open_fds` int(11) DEFAULT NULL,
			`listening_ports` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
			`folder_size_bytes` bigint(20) DEFAULT NULL,
			PRIMARY KEY (`id`),
			KEY `idx_proc_server` (`machine_id`,`server_name`,`ts`),
			KEY `idx_proc_pid` (`machine_id`,`pid`,`ts`),
			KEY `idx_ts` (`ts`)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
	};

	logger "Creating resource stats database tables...";
	$dbh->do($machines_sql);
	$dbh->do($machine_samples_sql);
	$dbh->do($process_samples_sql);
	logger "Resource stats database tables created/verified successfully.";
}

sub get_machine_id
{
	# Use hostname as machine identifier for better identification
	my $machine_id = `hostname`;
	chomp($machine_id);

	# Fallback to agent key only if hostname is not available
	if (!$machine_id || $machine_id eq '') {
		$machine_id = AGENT_KEY;
	}
	return $machine_id;
}

sub get_local_ip
{
	# Try to get the primary IP address
	my $ip = `hostname -I 2>/dev/null | awk '{print \$1}'`;
	chomp($ip);
	if (!$ip) {
		$ip = `ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \\K\\S+'`;
		chomp($ip);
	}
	return $ip || '127.0.0.1';
}

sub ensure_machine_registered
{
	my ($dbh, $machine_id, $hostname, $ip) = @_;
	my $table_prefix = STATS_TABLE_PREFIX || '';

	# Check if machine exists, if not insert it
	my $check_sql = "SELECT id FROM `${table_prefix}machines` WHERE machine_id = ?";
	my $sth = $dbh->prepare($check_sql);
	$sth->execute($machine_id);
	my $result = $sth->fetchrow_hashref();
	$sth->finish();

	if (!$result) {
		my $insert_sql = "INSERT INTO `${table_prefix}machines` (machine_id, hostname, ip) VALUES (?, ?, ?)";
		my $insert_sth = $dbh->prepare($insert_sql);
		$insert_sth->execute($machine_id, $hostname, $ip);
		$insert_sth->finish();
		logger "Registered new machine in database: $machine_id ($hostname)";
	}
}

sub get_extended_system_metrics
{
	# Get swap information
	my ($swap_used, $swap_total) = (0, 0);
	if (open(MEMINFO, '/proc/meminfo')) {
		while (<MEMINFO>) {
			$swap_total = $1 * 1024 if /SwapTotal\:\s+(\d+) kB/;
			$swap_used = ($swap_total - $1 * 1024) if /SwapFree\:\s+(\d+) kB/;
		}
		close(MEMINFO);
	}

	# Get disk path (root filesystem)
	my $disk_path = '/';

	# Get network interface and statistics
	my ($net_iface, $rx_bytes, $tx_bytes, $iface_speed) = ('', 0, 0, 0);
	my $default_iface = `ip route | grep default | head -1 | awk '{print \$5}'`;
	chomp($default_iface);

	if ($default_iface) {
		$net_iface = $default_iface;
		if (open(NETDEV, '/proc/net/dev')) {
			while (<NETDEV>) {
				if (/^\s*$default_iface:\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)/) {
					$rx_bytes = $1;
					$tx_bytes = $2;
					last;
				}
			}
			close(NETDEV);
		}

		# Try to get interface speed
		my $speed_file = "/sys/class/net/$default_iface/speed";
		if (open(SPEED, $speed_file)) {
			my $speed = <SPEED>;
			chomp($speed);
			$iface_speed = $speed if $speed =~ /^\d+$/;
			close(SPEED);
		}
	}

	return ($swap_used, $swap_total, $disk_path, $net_iface, $rx_bytes, $tx_bytes, $iface_speed);
}

sub insert_machine_sample
{
	my ($dbh, $machine_id, $cpu_usage, $mem_used, $mem_total, $mem_percent,
	    $swap_used, $swap_total, $disk_path, $disk_total, $disk_used, $disk_percent,
	    $net_iface, $rx_bytes, $tx_bytes, $iface_speed, $load_1min, $load_5min, $load_15min) = @_;

	my $table_prefix = STATS_TABLE_PREFIX || '';

	my $insert_sql = qq{
		INSERT INTO `${table_prefix}machine_samples` (
			machine_id, ts, load1, load5, load15, cpu_pct, mem_used_bytes, mem_total_bytes, mem_used_pct,
			swap_used_bytes, swap_total_bytes, disk_path, disk_total_bytes, disk_used_bytes, disk_used_pct,
			net_iface, rx_bytes, tx_bytes, iface_speed_mbps
		) VALUES (?, NOW(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	};

	my $sth = $dbh->prepare($insert_sql);
	$sth->execute(
		$machine_id, $load_1min, $load_5min, $load_15min, $cpu_usage, $mem_used, $mem_total, $mem_percent,
		$swap_used, $swap_total, $disk_path, $disk_total, $disk_used, $disk_percent,
		$net_iface, $rx_bytes, $tx_bytes, $iface_speed
	);
	$sth->finish();

	logger "Machine sample inserted for $machine_id: CPU=$cpu_usage%, MEM=$mem_percent%, DISK=$disk_percent%";
}

sub collect_and_insert_process_samples
{
	my ($dbh, $machine_id) = @_;
	my $table_prefix = STATS_TABLE_PREFIX || '';

	# Get list of running game server processes (screen sessions and their child processes)
	my @processes = ();

	# Create lookup table for home_id to server_id mapping from startup files
	my %home_id_to_server_id = ();
	if (opendir(STARTUP_DIR_EARLY, GAME_STARTUP_DIR)) {
		while (my $startup_file = readdir(STARTUP_DIR_EARLY)) {
			next if $startup_file =~ /^\./;

			my $startup_path = Path::Class::File->new(GAME_STARTUP_DIR, $startup_file);
			if (open(STARTUP_FILE_EARLY, '<', $startup_path)) {
				while (<STARTUP_FILE_EARLY>) {
					chomp;
					my ($server_id, $home_path, $server_exe, $run_dir, $startup_cmd, $server_port, $server_ip) = split(',', $_);
					# Extract home_id from home_path (e.g., /home/gameserver/1518 -> 1518)
					my ($extracted_home_id) = $home_path =~ /\/(\d+)$/;
					if ($extracted_home_id && $server_id) {
						$home_id_to_server_id{$extracted_home_id} = $server_id;
					}
				}
				close(STARTUP_FILE_EARLY);
			}
		}
		closedir(STARTUP_DIR_EARLY);
	}

	# Find screen sessions that might be game servers
	my @screen_sessions = `screen -ls 2>/dev/null | grep -E "\\s+[0-9]+\\." | awk '{print \$1}'`;

	foreach my $session (@screen_sessions) {
		chomp($session);
		next unless $session;

		# Extract server name from screen session name (format: GAME_HOME_000001518 or similar)
		my $server_name = $session;
		my $server_path = '/';

		# Try to extract home_id from GSP screen session and map to server_id
		if ($session =~ /GAME_HOME_0*(\d+)/) {
			my $home_id = $1;
			if (exists $home_id_to_server_id{$home_id}) {
				$server_name = $home_id_to_server_id{$home_id};  # Use actual server ID
			} else {
				$server_name = "GameServer_Home_$home_id";  # Fallback to home_id
			}
		} elsif ($session =~ /^(?:GSP_|SCREEN_)\w+_(.+)/) {
			$server_name = $1;
		} elsif ($session =~ /(\d+)\.(.+)/) {
			$server_name = $2;
		}

		# Get PIDs of processes in this screen session
		my $screen_pid_line = `screen -ls 2>/dev/null | grep '$session'`;
		my ($screen_pid) = $screen_pid_line =~ /(\d+)\./;

		if ($screen_pid && $screen_pid =~ /^\d+$/) {
			# Get child processes of the screen session
			my @child_pids = `pgrep -P $screen_pid 2>/dev/null`;
			push @child_pids, $screen_pid; # Include the screen process itself

			foreach my $pid (@child_pids) {
				chomp($pid);
				next unless $pid && $pid =~ /^\d+$/;

				# Get process information
				my $proc_info = get_process_info($pid, $server_name, $server_path);
				push @processes, $proc_info if $proc_info;
			}
		}
	}

	# Check startup files to find configured game server executables
	my %startup_executables = ();
	if (opendir(STARTUP_DIR, GAME_STARTUP_DIR)) {
		while (my $startup_file = readdir(STARTUP_DIR)) {
			next if $startup_file =~ /^\./;

			my $startup_path = Path::Class::File->new(GAME_STARTUP_DIR, $startup_file);
			if (open(STARTUP_FILE, '<', $startup_path)) {
				while (<STARTUP_FILE>) {
					chomp;
					my ($server_id, $home_path, $server_exe, $run_dir, $startup_cmd) = split(',', $_);
					if ($server_exe && $home_path) {
						# Extract just the executable name for process matching
						my ($exe_name) = $server_exe =~ /([^\/]+)$/;
						$startup_executables{$exe_name} = {
							server_id => $server_id,    # This is the actual server ID from startup file
							home_path => $home_path,
							full_exe => $server_exe
						} if $exe_name;
					}
				}
				close(STARTUP_FILE);
			}
		}
		closedir(STARTUP_DIR);
	}

	my $startup_exe_count = scalar(keys %startup_executables);
	logger "Found $startup_exe_count executable(s) from startup files for process monitoring" if $startup_exe_count > 0;
	logger "Resource monitoring will ONLY track processes that have corresponding startup files in the startups folder" if $startup_exe_count > 0;

	# Only look for processes that have corresponding startup files (managed game servers)
	# This prevents monitoring orphaned processes and unrelated services
	foreach my $exe_name (keys %startup_executables) {
		my @pids = `pgrep -f '$exe_name' 2>/dev/null`;
		foreach my $pid (@pids) {
			chomp($pid);
			next unless $pid && $pid =~ /^\d+$/;

			# Avoid duplicates by checking if we already processed this PID
			next if grep { $_->{pid} == $pid } @processes;

			# Only process if this executable has a startup file (is managed by GSE)
			if (exists $startup_executables{$exe_name}) {
				my $startup_info = $startup_executables{$exe_name};
				# Use the actual server ID from the startup file
				my $server_name = $startup_info->{server_id} || "Unknown_Server_PID$pid";
				my $server_path = $startup_info->{home_path} || '/';

				my $proc_info = get_process_info($pid, $server_name, $server_path);
				push @processes, $proc_info if $proc_info;
			}
			# If no startup file exists for this executable, we skip it (not managed by GSE)
		}
	}

	# Insert process samples into database
	my $insert_sql = qq{
		INSERT INTO `${table_prefix}process_samples` (
			machine_id, ts, server_name, server_path, pid, proc_name, cmd, cpu_pct, rss_bytes, vms_bytes,
			mem_pct, io_read_bytes, io_write_bytes, open_fds, listening_ports, folder_size_bytes
		) VALUES (?, NOW(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	};

	my $sth = $dbh->prepare($insert_sql);
	my $samples_inserted = 0;

	foreach my $proc (@processes) {
		eval {
			$sth->execute(
				$machine_id, $proc->{server_name}, $proc->{server_path}, $proc->{pid}, $proc->{proc_name},
				$proc->{cmd}, $proc->{cpu_pct}, $proc->{rss_bytes}, $proc->{vms_bytes}, $proc->{mem_pct},
				$proc->{io_read_bytes}, $proc->{io_write_bytes}, $proc->{open_fds}, $proc->{listening_ports},
				$proc->{folder_size_bytes}
			);
			$samples_inserted++;
		};
		if ($@) {
			logger "Error inserting process sample for PID $proc->{pid}: $@";
		}
	}

	$sth->finish();
	logger "Process samples inserted: $samples_inserted processes for $machine_id";
}

sub get_process_info
{
	my ($pid, $server_name, $server_path) = @_;

	# Get process stats from /proc/<pid>/stat
	my $stat_file = "/proc/$pid/stat";
	return undef unless -r $stat_file;

	my $stat_line = `cat $stat_file 2>/dev/null`;
	chomp($stat_line);
	return undef unless $stat_line;

	my @stat_fields = split /\s+/, $stat_line;
	my $proc_name = $stat_fields[1] || '';
	$proc_name =~ s/[()]//g; # Remove parentheses

	# Get command line
	my $cmd = `cat /proc/$pid/cmdline 2>/dev/null | tr '\\0' ' '`;
	chomp($cmd);

	# Get memory info from /proc/<pid>/status
	my ($rss_bytes, $vms_bytes) = (0, 0);
	if (open(STATUS, "/proc/$pid/status")) {
		while (<STATUS>) {
			$rss_bytes = $1 * 1024 if /VmRSS:\s+(\d+) kB/;
			$vms_bytes = $1 * 1024 if /VmSize:\s+(\d+) kB/;
		}
		close(STATUS);
	}

	# Get CPU percentage (using utime + stime from /proc/pid/stat)
	my $cpu_pct = 0;
	if (@stat_fields >= 15) {
		my $utime = $stat_fields[13] || 0;  # user time
		my $stime = $stat_fields[14] || 0;  # system time
		my $total_time = $utime + $stime;

		# Get system uptime and process start time for CPU calculation
		my $uptime_info = `cat /proc/uptime 2>/dev/null`;
		if ($uptime_info && $uptime_info =~ /^(\S+)/) {
			my $system_uptime = $1;
			my $starttime = $stat_fields[21] || 0; # process start time in clock ticks
			my $hertz = `getconf CLK_TCK 2>/dev/null` || 100; # clock ticks per second
			chomp($hertz);

			my $process_uptime = $system_uptime - ($starttime / $hertz);
			if ($process_uptime > 0) {
				$cpu_pct = sprintf("%.2f", ($total_time / $hertz) / $process_uptime * 100);
			}
		}
	}

	# Calculate memory percentage (of total system memory)
	my $mem_pct = 0;
	my $total_mem = `grep MemTotal /proc/meminfo | awk '{print \$2}'`;
	chomp($total_mem);
	if ($total_mem && $total_mem > 0) {
		$mem_pct = sprintf("%.2f", ($rss_bytes / 1024) / $total_mem * 100);
	}

	# Get I/O stats
	my ($io_read_bytes, $io_write_bytes) = (0, 0);
	if (open(IO, "/proc/$pid/io")) {
		while (<IO>) {
			$io_read_bytes = $1 if /read_bytes:\s+(\d+)/;
			$io_write_bytes = $1 if /write_bytes:\s+(\d+)/;
		}
		close(IO);
	}

	# Get open file descriptors count
	my $open_fds = 0;
	my $fd_dir = "/proc/$pid/fd";
	if (opendir(PROC_FD_DIR, $fd_dir)) {
		my @fds = readdir(PROC_FD_DIR);
		$open_fds = scalar(grep { /^\d+$/ } @fds);
		closedir(PROC_FD_DIR);
	}

	# Get listening ports (simplified)
	my $listening_ports = '';
	my $netstat_output = `netstat -tlnp 2>/dev/null | grep '$pid/' | awk '{print \$4}' | cut -d: -f2 | sort -n | uniq`;
	if ($netstat_output) {
		chomp($netstat_output);
		$listening_ports = join(',', split(/\n/, $netstat_output));
	}

	# Get folder size (for server_path) - try to find server directory from command line
	my $folder_size_bytes = 0;
	if ($cmd && $cmd =~ m{(/\S+)}) {
		# Try to extract directory from command line
		my $potential_path = $1;
		$potential_path =~ s/\/[^\/]+$//; # Remove filename, keep directory
		if (-d $potential_path && $potential_path ne '/') {
			$server_path = $potential_path;
			# Get folder size (this is expensive, so we limit it)
			my $du_output = `timeout 5 du -sb '$potential_path' 2>/dev/null | awk '{print \$1}'`;
			chomp($du_output);
			$folder_size_bytes = $du_output if $du_output && $du_output =~ /^\d+$/;
		}
	}

	return {
		server_name => $server_name,
		server_path => $server_path,
		pid => $pid,
		proc_name => $proc_name,
		cmd => $cmd,
		cpu_pct => $cpu_pct,
		rss_bytes => $rss_bytes,
		vms_bytes => $vms_bytes,
		mem_pct => $mem_pct,
		io_read_bytes => $io_read_bytes,
		io_write_bytes => $io_write_bytes,
		open_fds => $open_fds,
		listening_ports => $listening_ports,
		folder_size_bytes => $folder_size_bytes
	};
}

sub exec
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($command) 		= decrypt_params(@_);
	my @cmdret			= `$command 2>/dev/null`;
	my $encoded_content	= encode_list(@cmdret);
	return "1;$encoded_content";
}

# used in conjunction with the clone_home feature in the web panel
# this actually does the file copies
sub clone_home
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($source_home, $dest_home, $owner) = decrypt_params(@_);
	my ($time_start, $time_stop, $time_diff);
	logger "Copying from $source_home to $dest_home...";

	# check size of source_home, make sure we have space to copy
	if (!-e $source_home)
	{
		logger "ERROR - $source_home does not exist";
		return 0;
	}
	logger "Game home $source_home exists...copy will proceed";

	# start the copy, and a timer
	$time_start = time();
	if (!dircopy("$source_home", "$dest_home"))
	{
		$time_stop = time();
		$time_diff = $time_stop - $time_start;
		logger
		  "Error occured after $time_diff seconds during copy of $source_home to $dest_home - $!";
		return 0;
	}
	else
	{
		$time_stop = time();
		$time_diff = $time_stop - $time_start;
		logger
		  "Home clone completed successfully to $dest_home in $time_diff seconds";
		return 1;
	}
}

# used to delete the game home from the file system when it's removed from the panel
sub remove_home
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_path_del) = decrypt_params(@_);

	if (!-e $home_path_del)
	{
		logger "ERROR - $home_path_del does not exist...nothing to do";
		return 0;
	}

	my $owner = get_path_owner($home_path_del);
	secure_path_without_decrypt('chattr-i', $home_path_del);
	my $deleted_home_dir = sudo_exec_without_decrypt('rm -rf \''.$home_path_del.'\'');

	if (defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		if ($owner ne SERVER_RUNNER_USER && begins_with($owner,'gamehome')){
			my $kill_all_user = sudo_exec_without_decrypt('killall -u "' . $owner . '"');
			my $deleted_user = sudo_exec_without_decrypt('userdel -r "' . $owner . '"');
			my ($retval_del_user, $enc_out_del_user) = split(/;/, $deleted_user, 2);
			if ($retval_del_user == 1){
				logger "Removing and deleting user $owner";
			}
			my $deleted_user_group = sudo_exec_without_decrypt('groupdel "' . $owner . '"');
		}
	}

	my ($retval, $enc_out) = split(/;/, $deleted_home_dir, 2);
	if ($retval == 1){
		logger "Deletetion of $home_path_del successful!";
	}else{
		logger "Deletetion of $home_path_del failed!";
	}

	return 1;
}

sub restart_server
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return restart_server_without_decrypt(decrypt_params(@_));
}

### Restart the server
## return -2 CANT STOP
## return -1  CANT START (no startup file found that mach the home_id, port and ip)
## return 1 Restart OK
sub restart_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $home_path, $server_exe, $run_dir,
		$cmd, $cpu, $nice, $preStart, $envVars, $game_key, $console_log, $restart_reason) = @_;
	$restart_reason = "panel_restart" unless(defined($restart_reason) && $restart_reason ne "");
	my $correlation_id = new_correlation_id();
	my $restart_started_event = $restart_reason eq "scheduled_restart" ? "scheduled_restart_started" : "automatic_restart_started";
	my $restart_success_event = $restart_reason eq "scheduled_restart" ? "scheduled_restart_succeeded" : "automatic_restart_succeeded";
	my $restart_failed_event = $restart_reason eq "scheduled_restart" ? "scheduled_restart_failed" : "automatic_restart_failed";
	my $report_restart_events = ($restart_reason eq "scheduled_restart" || $restart_reason eq "automatic_restart") ? 1 : 0;
	queue_agent_event($restart_started_event, "info", {
		home_id => $home_id,
		ip => $server_ip,
		game_port => $server_port,
		restart_reason => $restart_reason,
		correlation_id => $correlation_id,
		message => "Restart operation started."
	}) if($report_restart_events);

		if (stop_server_without_decrypt($home_id, $server_ip,
										$server_port, $control_protocol,
										$control_password, $control_type, $home_path) == 0)
	{
		# Stop has confirmed the port is free; GameManager frees it again before launch. No wait.
		if (universal_start_without_decrypt($home_id, $home_path, $server_exe, $run_dir,
											$cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log) == 1)
		{
			queue_agent_event($restart_success_event, "info", {
				home_id => $home_id,
				game_home_path => $home_path,
				ip => $server_ip,
				game_port => $server_port,
				restart_reason => $restart_reason,
				correlation_id => $correlation_id,
				message => "Restart command completed; status polling will confirm process and port readiness."
			}) if($report_restart_events);
			return 1;
		}
		else
		{
			queue_agent_event($restart_failed_event, "error", {
				home_id => $home_id,
				game_home_path => $home_path,
				ip => $server_ip,
				game_port => $server_port,
				restart_reason => $restart_reason,
				correlation_id => $correlation_id,
				message => "Restart failed because the server start path returned an error."
			}) if($report_restart_events);
			return -1;
		}
	}
	else
	{
		queue_agent_event($restart_failed_event, "error", {
			home_id => $home_id,
			ip => $server_ip,
			game_port => $server_port,
			restart_reason => $restart_reason,
			correlation_id => $correlation_id,
			message => "Restart failed because the server could not be stopped."
		}) if($report_restart_events);
		return -2;
	}
}

sub find_user_by_screen_id
{
	my ($screen_id) = @_;

	my $screen_user = SERVER_RUNNER_USER;

	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$screen_user = `whoami`;
		chomp $screen_user;
	}

	my $ret = sudo_exec_without_decrypt('find /var/run/screen -name "*'.$screen_id.'"');

	my ($retval, $enc_out) = split(/;/, $ret, 2);

	if($retval != 1)
	{
		return $screen_user;
	}

	if( defined($enc_out) && $enc_out =~ /^(.+)\\n/ )
	{
		my @dec_out = ();
		foreach my $line (split /\\n/, $enc_out) {
			my $dec_line = decode_base64($line);
			push @dec_out, $dec_line;
		}

		my @path_parts = split /\//, $dec_out[0];

		if ($#path_parts == 5)
		{
			if($path_parts[5] =~ /^(\d+)\.$screen_id$/)
			{
				if ($path_parts[4] =~ /^S-/)
				{
					my $parseval = $path_parts[4];
					$parseval =~ s/^S-//g;
					my $uid = `id -u $parseval`;
					if( $uid =~ /^(\d+)$/ )
					{
						$screen_user = $parseval;
					}
				}
			}
		}
	}

	return $screen_user;
}

sub get_path_owner
{
	my ($path) = @_;

	my $path_owner = SERVER_RUNNER_USER;

	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$path_owner = `whoami`;
		chomp $path_owner;
	}

	if(-d $path)
	{
		my $ret = sudo_exec_without_decrypt('stat -c "%U" "'.$path.'"');

		my ($retval, $enc_out) = split(/;/, $ret, 2);

		if($retval != 1)
		{
			return $path_owner;
		}

		if( defined($enc_out) && $enc_out =~ /^(.+)\\n/ )
		{
			my @dec_out = ();
			foreach my $line (split /\\n/, $enc_out) {
				my $dec_line = decode_base64($line);
				push @dec_out, $dec_line;
			}

			my $parseval = $dec_out[0];
			my $uid = `id -u $parseval`;

			if( $uid =~ /^(\d+)$/ )
			{
				$path_owner = $parseval;
			}
		}
	}

	return $path_owner;
}

sub sudo_exec
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $sudo_exec = &decrypt_param(@_);
	return sudo_exec_without_decrypt($sudo_exec);
}

sub sudo_exec_without_decrypt
{
	my ($sudo_exec, $as_user) = @_;
	$sudo_exec =~ s/('+)/'"$1"'/g;
	if( !defined($as_user) )
	{
		$as_user = "root";
	}

	my $command = "echo '$SUDOPASSWD'|sudo -kS -p \"<prompt>\" su -c '$sudo_exec;echo \$?' $as_user 2>&1";
	my @cmdret = qx($command);
	$cmdret[0] =~ s/^<prompt>//g if defined $cmdret[0];
	chomp(@cmdret);

	my $ret = pop(@cmdret);
	chomp($ret);

	if ("X$ret" eq "X0")
	{
		return "1;".encode_list(@cmdret);
	}

	return -1;
}

sub sudo_exec_without_decrypt_no_return
{
	my ($sudo_exec, $as_user) = @_;
	$sudo_exec =~ s/('+)/'"$1"'/g;
	if( !defined($as_user) )
	{
		$as_user = "root";
	}

	my $command = "echo '$SUDOPASSWD'|sudo -kS -p \"<prompt>\" su -c '$sudo_exec' $as_user 2>&1";
	my @cmdret = qx($command);
	$cmdret[0] =~ s/^<prompt>//g if defined $cmdret[0];
	chomp(@cmdret);

	my $ret = pop(@cmdret);
	chomp($ret);

	if ("X$ret" eq "X0")
	{
		return "1;".encode_list(@cmdret);
	}

	return -1;
}

sub secure_path
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return secure_path_without_decrypt(decrypt_params(@_));
}

sub secure_path_without_decrypt
{
	my ($action, $file_path, $returnType) = @_;
	my $checkIfFileExists = 1;

	if(defined $returnType && $returnType eq "str"){
		$checkIfFileExists = 0;
	}

	if($checkIfFileExists){
		if(! -e $file_path){
			return -1;
		}
	}

	$file_path =~ s/('+)/'\"$1\"'/g;
	if($action eq "chattr+i")
	{
		if(defined $returnType && $returnType eq "str"){
			return 'chattr -Rf +i \''.$file_path.'\'';
		}else{
			return sudo_exec_without_decrypt('chattr -Rf +i \''.$file_path.'\'');
		}
	}
	elsif($action eq "chattr-i")
	{
		if(defined $returnType && $returnType eq "str"){
			return 'chattr -Rf -i \''.$file_path.'\'';
		}else{
			return sudo_exec_without_decrypt('chattr -Rf -i \''.$file_path.'\'');
		}
	}

	return -1;
}

sub get_chattr
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($file_path) = decrypt_params(@_);
	my $file = $file_path;
	$file_path =~ s/('+)/'\"$1\"'/g;
	return sudo_exec_without_decrypt('(lsattr \''.$file_path.'\' | sed -e "s#'.$file.'##g")|grep -o i');
}

sub ftp_mgr
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($action, $login, $password, $home_path) = decrypt_params(@_);

	my $uid = `id -u`;
	chomp $uid;
	my $gid = `id -g`;
	chomp $gid;

	$login =~ s/('+)/'\"$1\"'/g;
	$password =~ s/('+)/'\"$1\"'/g;
	$home_path =~ s/('+)/'\"$1\"'/g;

	if(preference_enabled('manages_ftp', 'manages_ftp', '1')){
		if( defined($Cfg::Preferences{ftp_method}) && $Cfg::Preferences{ftp_method} eq "IspConfig")
		{
			use constant ISPCONFIG_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'IspConfig');
			use constant FTP_USERS_DIR => Path::Class::Dir->new(ISPCONFIG_DIR, 'ftp_users');

			if (!-d FTP_USERS_DIR && !mkdir FTP_USERS_DIR)
			{
				print "Could not create " . FTP_USERS_DIR . " directory $!.";
				return -1;
			}

			chdir ISPCONFIG_DIR;

			if($action eq "list")
			{
				my $users_list;
				opendir(USERS, FTP_USERS_DIR);
				while (my $username = readdir(USERS))
				{
					# Skip . and ..
					next if $username =~ /^\./;
					$users_list .= `php-cgi -f sites_ftp_user_get.php username=\'$username\'`;
				}
				closedir(USERS);
				if( defined($users_list) )
				{
					return "1;".encode_list($users_list);
				}
			}
			elsif($action eq "userdel")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_delete.php username=\'$login\'`);
			}
			elsif($action eq "useradd")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_add.php username=\'$login\' password=\'$password\' dir=\'$home_path\' uid=$uid gid=$gid`);
			}
			elsif($action eq "passwd")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_update.php type=passwd username=\'$login\' password=\'$password\'`);
			}
			elsif($action eq "show")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_get.php type=detail username=\'$login\'`);
			}
			elsif($action eq "usermod")
			{
				return "1;".encode_list(`php-cgi -f sites_ftp_user_update.php username=\'$login\' password=\'$password\'`);
			}
		}
		elsif(defined($Cfg::Preferences{ftp_method}) && $Cfg::Preferences{ftp_method} eq "EHCP" && (-e "/etc/init.d/ehcp" || -e "/lib/systemd/system/ehcp.service" || -e "/etc/systemd/system/ehcp.service" ))
		{
			use constant EHCP_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'EHCP');

			chdir EHCP_DIR;
			my $phpScript;
			my $phpOut;
			my $gidTwo = SERVER_RUNNER_USER;

			chmod 0777, 'ehcp_ftp_log.txt';

			# In order to access the FTP files, the vsftpd user needs to be added to the GSE agent group
			sudo_exec_without_decrypt("usermod -a -G '$gid' ftp");
			sudo_exec_without_decrypt("usermod -a -G '$gid' vsftpd");
			sudo_exec_without_decrypt("usermod -a -G '$gidTwo' ftp");
			sudo_exec_without_decrypt("usermod -a -G '$gidTwo' vsftpd");

			if($action eq "list")
			{
				return "1;".encode_list(`php-cgi -f listAllUsers.php`);
			}
			elsif($action eq "userdel")
			{
				$phpScript = `php-cgi -f delAccount.php username=\'$login\'`;
				$phpOut = `php-cgi -f syncftp.php`;
				return $phpScript;
			}
			elsif($action eq "useradd")
			{
				$phpScript = `php-cgi -f addAccount.php username=\'$login\' password=\'$password\' dir=\'$home_path\' uid=$uid gid=$gid`;
				$phpOut = `php-cgi -f syncftp.php`;
				return $phpScript;
			}
			elsif($action eq "passwd")
			{
				$phpScript = `php-cgi -f updatePass.php username=\'$login\' password=\'$password\'`;
				$phpOut = `php-cgi -f syncftp.php`;
				return $phpScript ;
			}
			elsif($action eq "show")
			{
				return "1;".encode_list(`php-cgi -f showAccount.php username=\'$login\'`);
			}
			elsif($action eq "usermod")
			{
				$phpScript = `php-cgi -f updateInfo.php username=\'$login\' password=\'$password\'`;
				$phpOut = `php-cgi -f syncftp.php`;
				return $phpScript;
			}
		}
		elsif(defined($Cfg::Preferences{ftp_method}) && $Cfg::Preferences{ftp_method} eq "proftpd" && -e $Cfg::Preferences{proftpd_conf_path})
		{
			chdir $Cfg::Preferences{proftpd_conf_path};
			if($action eq "list")
			{
				my $users;
				open(PASSWD, 'ftpd.passwd');
				while (<PASSWD>) {
					chomp;
					my($login, $passwd, $uid, $gid, $gcos, $home, $shell) = split(/:/);
					$users .= "$login\t$home\n";
				}
				close(PASSWD);
				return "1;".encode_list($users);
			}
			elsif($action eq "userdel")
			{
				return sudo_exec_without_decrypt("ftpasswd --passwd --delete-user --name='$login'");
			}
			elsif($action eq "useradd")
			{
				return sudo_exec_without_decrypt("echo '$password' | ftpasswd --passwd --name='$login' --home='$home_path' --shell=/bin/false --uid=$uid --gid=$gid --stdin");
			}
			elsif($action eq "passwd")
			{
				return sudo_exec_without_decrypt("echo '$password' | ftpasswd --passwd --change-password --name='$login' --stdin");
			}
			elsif($action eq "show")
			{
				return 1;
			}
			elsif($action eq "usermod")
			{
				return 1;
			}
			chdir AGENT_RUN_DIR;
		}
		else
		{
			if($action eq "list")
			{
				return sudo_exec_without_decrypt("pure-pw list");
			}
			elsif($action eq "userdel")
			{
				return sudo_exec_without_decrypt("pure-pw userdel '$login' && pure-pw mkdb");
			}
			elsif($action eq "useradd")
			{
				return sudo_exec_without_decrypt("(echo '$password'; echo '$password') | pure-pw useradd '$login' -u $uid -g $gid -d '$home_path' && pure-pw mkdb");
			}
			elsif($action eq "passwd")
			{
				return sudo_exec_without_decrypt("(echo '$password'; echo '$password') | pure-pw passwd '$login' && pure-pw mkdb");
			}
			elsif($action eq "show")
			{
				return sudo_exec_without_decrypt("pure-pw show '$login'");
			}
			elsif($action eq "usermod")
			{
				my $update_account = "pure-pw usermod '$login' -u $uid -g $gid";

				my @account_settings = split /[\n]+/, $password;

				foreach my $setting (@account_settings) {
					my ($key, $value) = split /[\t]+/, $setting;

					if( $key eq 'Directory' )
					{
						$value =~ s/('+)/'\"$1\"'/g;
						$update_account .= " -d '$value'";
					}

					if( $key eq 'Full_name' )
					{
						if(  $value ne "" )
						{
							$value =~ s/('+)/'\"$1\"'/g;
							$update_account .= " -c '$value'";
						}
						else
						{
							$update_account .= ' -c ""';
						}
					}

					if( $key eq 'Download_bandwidth' && $value ne ""  )
					{
						my $Download_bandwidth;
						if($value eq 0)
						{
							$Download_bandwidth = "\"\"";
						}
						else
						{
							$Download_bandwidth = $value;
						}
						$update_account .= " -t " . $Download_bandwidth;
					}

					if( $key eq 'Upload___bandwidth' && $value ne "" )
					{
						my $Upload___bandwidth;
						if($value eq 0)
						{
							$Upload___bandwidth = "\"\"";
						}
						else
						{
							$Upload___bandwidth = $value;
						}
						$update_account .= " -T " . $Upload___bandwidth;
					}

					if( $key eq 'Max_files' )
					{
						if( $value eq "0" )
						{
							$update_account .= ' -n ""';
						}
						elsif( $value ne "" )
						{
							$update_account .= " -n " . $value;
						}
						else
						{
							$update_account .= ' -n ""';
						}
					}

					if( $key eq 'Max_size' )
					{
						if( $value ne "" && $value ne "0" )
						{
							$update_account .= " -N " . $value;
						}
						else
						{
							$update_account .= ' -N ""';
						}
					}

					if( $key eq 'Ratio' && $value ne ""  )
					{
						my($upload_ratio,$download_ratio) = split/:/,$value;

						if($upload_ratio eq "0")
						{
							$upload_ratio = "\"\"";
						}
						$update_account .= " -q " . $upload_ratio;

						if($download_ratio eq "0")
						{
							$download_ratio = "\"\"";
						}
						$update_account .= " -Q " . $download_ratio;
					}

					if( $key eq 'Allowed_client_IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -r " . $value;
						}
						else
						{
							$update_account .= ' -r ""';
						}
					}

					if( $key eq 'Denied__client_IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -R " . $value;
						}
						else
						{
							$update_account .= ' -R ""';
						}
					}

					if( $key eq 'Allowed_local__IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -i " . $value;
						}
						else
						{
							$update_account .= ' -i ""';
						}
					}

					if( $key eq 'Denied__local__IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -I " . $value;
						}
						else
						{
							$update_account .= ' -I ""';
						}
					}


					if( $key eq 'Max_sim_sessions' && $value ne "" )
					{
						$update_account .= " -y " . $value;
					}

					if ( $key eq 'Time_restrictions'  )
					{
						if( $value eq "0000-0000")
						{
							$update_account .= ' -z ""';
						}
						elsif( $value ne "" )
						{
							$update_account .= " -z " . $value;
						}
						else
						{
							$update_account .= ' -z ""';
						}
					}
				}
				$update_account .=" && pure-pw mkdb";
				# print $update_account;
				return sudo_exec_without_decrypt($update_account);
			}
		}
	}
	return 0;
}

sub start_fastdl
{
	if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
	{
		system('perl FastDownload/ForkedDaemon.pm &');
		sleep(1);
		return 1;
	}
	else
	{
		return -2;
	}
}

sub stop_fastdl
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return stop_fastdl_without_decrypt();
}

sub stop_fastdl_without_decrypt
{
	my $pid;
	open(PIDFILE, '<', FD_PID_FILE)
	  || logger "Error reading pid file $!",1;
	while (<PIDFILE>)
	{
		$pid = $_;
		chomp $pid;
	}
	close(PIDFILE);
	my $cnt = kill 9, $pid;
	if ($cnt == 1)
	{
		logger "Fast Download Daemon Stopped.",1;
		return 1;
	}
	else
	{
		logger "Fast Download Daemon with pid $pid can not be stopped.",1;
		return -1;
	}
}

sub restart_fastdl
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return restart_fastdl_without_decrypt();
}

sub restart_fastdl_without_decrypt
{
	if((fastdl_status_without_decrypt() == -1) || (stop_fastdl_without_decrypt() == 1))
	{
		if(start_fastdl() == 1)
		{
			# Success
			return 1;
		}
		# Cant start
		return -2;
	}
	# Cant stop
	return -3;
}

sub fastdl_status
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return fastdl_status_without_decrypt();
}

sub fastdl_status_without_decrypt
{
	my $pid;
	if(!open(PIDFILE, '<', FD_PID_FILE))
	{
		logger "Error reading pid file $!";
		return -1;
	}
	while (<PIDFILE>)
	{
		$pid = $_;
		chomp $pid;
	}
	close(PIDFILE);
	my $cnt = kill 0, $pid;
	if ($cnt == 1)
	{
		return 1;
	}
	else
	{
		return -1;
	}
}

sub fastdl_get_aliases
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my %aliases;
	my $i;
	my @file_lines;
	if(-d FD_ALIASES_DIR)
	{
		if( !opendir(ALIASES, FD_ALIASES_DIR) )
		{
			logger "Error openning aliases directory " . FD_ALIASES_DIR . ", $!";
		}
		else
		{
			while (my $alias = readdir(ALIASES))
			{
				# Skip . and ..
				next if $alias =~ /^\./;
				if( !open(ALIAS, '<', Path::Class::Dir->new(FD_ALIASES_DIR, $alias)) )
				{
					logger "Error reading alias '$alias', $!";
				}
				else
				{
					$i = 0;
					@file_lines = ();
					while (<ALIAS>)
					{
						chomp $_;
						$file_lines[$i] = $_;
						$i++;
					}
					close(ALIAS);
					$aliases{$alias}{home}                  = $file_lines[0];
					$aliases{$alias}{match_file_extension}  = $file_lines[1];
					$aliases{$alias}{match_client_ip}       = $file_lines[2];
				}
			}
			closedir(ALIASES);
		}
	}
	else
	{
		logger "Aliases directory '" . FD_ALIASES_DIR . "' does not exist or is inaccessible.";
	}
	return {%aliases};
}

sub fastdl_del_alias
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	foreach my $alias (decrypt_params(@_))
	{
		unlink Path::Class::File->new(FD_ALIASES_DIR, $alias);
	}
	return restart_fastdl_without_decrypt();
}

sub fastdl_add_alias
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($alias,$home,$match_file_extension,$match_client_ip) = decrypt_params(@_);
	if(!-e FD_ALIASES_DIR)
	{
		if(!mkdir FD_ALIASES_DIR)
		{
			logger "ERROR - Failed to create " . FD_ALIASES_DIR . " directory.";
			return -1;
		}
	}
	my $alias_path = Path::Class::File->new(FD_ALIASES_DIR, $alias);
	if (!open(ALIAS, '>', $alias_path))
	{
		logger "ERROR - Failed to open ".$alias_path." for writing.";
		return -1;
	}
	else
	{
		print ALIAS "$home\n";
		print ALIAS "$match_file_extension\n";
		print ALIAS "$match_client_ip";
		close(ALIAS);
		return restart_fastdl_without_decrypt();
	}
}

sub fastdl_get_info
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
	{
		delete $INC{"FastDownload/Settings.pm"};
		require "FastDownload/Settings.pm"; # Settings for Fast Download Daemon.
		if(not defined $FastDownload::Settings{autostart_on_agent_startup})
		{
			$FastDownload::Settings{autostart_on_agent_startup} = 0;
		}
		return {'port'						=>	$FastDownload::Settings{port},
				'ip'						=>	$FastDownload::Settings{ip},
				'listing'					=>	$FastDownload::Settings{listing},
				'autostart_on_agent_startup'=>	$FastDownload::Settings{autostart_on_agent_startup}};
	}
	return -1
}

sub fastdl_create_config
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if(!-e FD_DIR)
	{
		if(!mkdir FD_DIR)
		{
			logger "ERROR - Failed to create " . FD_DIR . " directory.";
			return -1;
		}
	}
	my ($fd_address, $fd_port, $listing, $autostart_on_agent_startup) = decrypt_params(@_);
	my $settings_string = "%FastDownload::Settings = (\n".
						  "\tport  => $fd_port,\n".
						  "\tip => '$fd_address',\n".
						  "\tlisting => $listing,\n".
						  "\tautostart_on_agent_startup => $autostart_on_agent_startup,\n".
						  ");";
	my $settings = Path::Class::File->new(FD_DIR, 'Settings.pm');
	if (!open(SETTINGS, '>', $settings))
	{
		logger "ERROR - Failed to open $settings for writing.";
		return -1;
	}
	else
	{
		print SETTINGS $settings_string;
		close(SETTINGS);
	}
	logger "$settings file written successfully.";
	return 1;
}

sub agent_read_first_line
{
	my ($path) = @_;
	return "" unless(defined($path) && -f $path);
	if(open(my $fh, '<', $path))
	{
		my $line = <$fh>;
		close($fh);
		chomp($line) if(defined($line));
		return defined($line) ? $line : "";
	}
	return "";
}

sub agent_cpu_usage_percent
{
	my $first = agent_read_first_line('/proc/stat');
	return "" unless($first =~ /^cpu\s+/);
	my @a = split(/\s+/, $first);
	sleep 1;
	my $second = agent_read_first_line('/proc/stat');
	return "" unless($second =~ /^cpu\s+/);
	my @b = split(/\s+/, $second);
	my ($idle_a, $idle_b) = ($a[4] || 0, $b[4] || 0);
	my ($total_a, $total_b) = (0, 0);
	for(my $i = 1; $i < @a; $i++) { $total_a += $a[$i] || 0; }
	for(my $i = 1; $i < @b; $i++) { $total_b += $b[$i] || 0; }
	my $total = $total_b - $total_a;
	return "" if($total <= 0);
	return sprintf("%.2f", 100 * (($total - ($idle_b - $idle_a)) / $total));
}

sub agent_ram_usage_percent
{
	my ($total, $available, $free, $buffers, $cached) = (0, 0, 0, 0, 0);
	return "" unless(open(my $fh, '<', '/proc/meminfo'));
	while(my $line = <$fh>)
	{
		$total = $1 if($line =~ /^MemTotal:\s+([0-9]+)\s+kB/);
		$available = $1 if($line =~ /^MemAvailable:\s+([0-9]+)\s+kB/);
		$free = $1 if($line =~ /^MemFree:\s+([0-9]+)\s+kB/);
		$buffers = $1 if($line =~ /^Buffers:\s+([0-9]+)\s+kB/);
		$cached = $1 if($line =~ /^Cached:\s+([0-9]+)\s+kB/);
	}
	close($fh);
	return "" if($total <= 0);
	my $used = $available > 0 ? $total - $available : $total - $free - $buffers - $cached;
	return sprintf("%.2f", 100 * ($used / $total));
}

sub agent_disk_usage_percent
{
	my @lines = `df -P -x tmpfs -x devtmpfs 2>/dev/null`;
	my $max = "";
	foreach my $line (@lines)
	{
		next unless($line =~ /\s([0-9]{1,3})%\s+\S+\s*$/);
		$max = $1 if($max eq "" || $1 > $max);
	}
	return $max eq "" ? "" : sprintf("%.2f", $max);
}

sub agent_version
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $os = `uname -sr 2>/dev/null`;
	chomp($os);
	return component_update_response(success => 1, status => 'ok', agent_version => AGENT_VERSION, protocol_version => AGENT_PROTOCOL_VERSION, os => $os, install_path => AGENT_RUN_DIR);
}

sub agent_resource_snapshot
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $load = agent_read_first_line('/proc/loadavg');
	$load =~ s/\s+$//;
	my $os = `uname -sr 2>/dev/null`;
	chomp($os);
	return component_update_response(
		success => 1,
		status => 'ok',
		message => 'Resource snapshot collected.',
		os => $os,
		agent_version => AGENT_VERSION,
		protocol_version => AGENT_PROTOCOL_VERSION,
		install_path => AGENT_RUN_DIR,
		cpu_percent => agent_cpu_usage_percent(),
		ram_percent => agent_ram_usage_percent(),
		disk_percent => agent_disk_usage_percent(),
		load_average => $load
	);
}

sub agent_hardware_inventory
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $inventory = eval { collect_linux_inventory(game_path => AGENT_RUN_DIR) };
	return component_update_response(success => 0, status => 'error', message => 'Hardware inventory failed.') unless($inventory);
	return component_update_response(
		success => 1,
		status => 'ok',
		message => 'Hardware inventory collected.',
		agent_version => AGENT_VERSION,
		protocol_version => AGENT_PROTOCOL_VERSION,
		inventory_schema => $inventory->{schema_version},
		inventory_json => JSON::PP->new->canonical->encode($inventory)
	);
}

sub agent_update_status
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my %data = (success => 0, status => 'not_started', message => 'No agent update has been recorded.', state_path => AGENT_UPDATE_STATE_FILE, request_path => AGENT_UPDATE_REQUEST_FILE, log_path => AGENT_UPDATE_LOG_FILE);
	if(open(my $fh, '<', AGENT_UPDATE_STATE_FILE))
	{
		local $/;
		my $json = <$fh>;
		close($fh);
		my $decoded = eval { decode_json($json) };
		if(ref($decoded) eq 'HASH')
		{
			%data = (%data, %$decoded);
			$data{success} = ($data{status} && $data{status} eq 'completed') ? 1 : 0;
		}
	}
	return component_update_response(%data);
}


sub agent_update_shell_quote
{
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/'/'\\''/g;
	return "'$value'";
}

sub write_agent_update_state
{
	my (%state) = @_;
	my $state_file = AGENT_UPDATE_STATE_FILE . '';
	my $tmp = $state_file . ".tmp.$$";
	open(my $fh, '>', $tmp) or return 0;
	print $fh encode_json(\%state) . "\n";
	close($fh);
	return rename($tmp, $state_file) ? 1 : 0;
}

# Downloads a release zip, verifies its SHA-256, then starts the on-demand
# update helper detached. The helper stops this agent, swaps the files,
# starts the agent again, and restores the backup if it does not come back.
# Mirrors the Windows agent's archive-based update; see agent_update_helper.sh.
sub start_agent_update
{
	my (%cfg) = @_;
	# The RPC process ignores child signals, so system() would return -1 for a download that
	# worked ("Could not download the release archive"). Real exit codes are needed here.
	local $SIG{CHLD} = 'DEFAULT';
	my $component = $cfg{component} || 'linux_agent';
	my $archive_url = $cfg{archive_url} || '';
	my $checksum = lc($cfg{checksum} || '');
	my $version = $cfg{version} || '';
	return component_update_response(success => 0, status => 'invalid_component', message => 'Invalid component.') if($component ne 'linux_agent' && $component ne 'windows_agent');
	return component_update_response(success => 0, status => 'invalid_archive_url', message => 'Provide an https archive_url.') if($archive_url !~ m{^https://} || $archive_url =~ /[\r\n\0\s]/);
	return component_update_response(success => 0, status => 'invalid_checksum', message => 'Invalid SHA-256 checksum.') if($checksum !~ /^[0-9a-f]{64}$/);
	return component_update_response(success => 0, status => 'invalid_version', message => 'Invalid release version.') if($version !~ /^[A-Za-z0-9._\/-]{1,128}$/);

	# Refuse a second update while one is still running (state written in the last 15 minutes).
	my $state_file = AGENT_UPDATE_STATE_FILE;
	if (-f $state_file && (time - (stat($state_file))[9]) < 900 && open(my $sfh, '<', $state_file))
	{
		local $/;
		my $raw = <$sfh>;
		close($sfh);
		return component_update_response(success => 0, status => 'busy', message => 'An update is already running. Wait for it to finish.')
			if (defined $raw && $raw =~ /"status"\s*:\s*"running"/);
	}

	my $stage_dir = Path::Class::Dir->new(AGENT_RUN_DIR, 'agent_update_stage')->stringify;
	system('rm', '-rf', $stage_dir);
	mkdir($stage_dir) or return component_update_response(success => 0, status => 'write_failed', message => "Cannot create staging folder: $!");
	my $zip = "$stage_dir/release.zip";

	if(system('curl', '-fsSL', '--max-time', '300', '-o', $zip, $archive_url) != 0)
	{
		return component_update_response(success => 0, status => 'download_failed', message => 'Could not download the release archive.');
	}

	my $sha_output = `sha256sum \Q$zip\E 2>/dev/null`;
	my ($actual) = $sha_output =~ /^([0-9a-fA-F]{64})/;
	$actual = lc($actual || '');
	if($actual ne $checksum)
	{
		write_agent_update_state(status => 'failed', message => 'Downloaded release checksum did not match; nothing was changed.', version_target => $version, component => $component, updated_at => scalar gmtime(), rollback_performed => 0);
		return component_update_response(success => 0, status => 'checksum_mismatch', message => 'Downloaded release checksum did not match; nothing was changed.');
	}

	my %state = (
		status => 'running',
		message => 'Release downloaded and verified. The agent is stopping; the update helper will install it and restart the agent.',
		version_target => $version,
		version_before => AGENT_VERSION,
		component => $component,
		rollback_performed => 0,
		updated_at => scalar gmtime(),
	);
	write_agent_update_state(%state);

	my $service = $Cfg::Config{service_name} || 'agent_core';
	$service = 'agent_core' unless $service =~ /^[A-Za-z0-9_.-]{1,64}$/;
	my $helper = Path::Class::File->new(AGENT_RUN_DIR, 'agent_update_helper.sh')->stringify;
	my $command = join(' ',
		'nohup', 'bash', agent_update_shell_quote($helper),
		'--agent-dir', agent_update_shell_quote(AGENT_RUN_DIR . ''),
		'--zip', agent_update_shell_quote($zip),
		'--sha256', agent_update_shell_quote($checksum),
		'--version', agent_update_shell_quote($version),
		'--agent-pid', $$,
		'--service-name', agent_update_shell_quote($service),
		'--state-file', agent_update_shell_quote(AGENT_UPDATE_STATE_FILE . ''),
		'--log-file', agent_update_shell_quote(AGENT_UPDATE_LOG_FILE . ''),
		'>/dev/null 2>&1', '&'
	);
	system($command);
	logger("Agent update to $version started; update helper launched.");
	return component_update_response(%state, success => 1);
}
sub agent_self_update
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($payload) = decrypt_params(@_);
	my %cfg = component_update_parse_payload($payload);
		# The panel now sends a release archive_url+checksum+version for an
		# on-demand update (the same payload the Windows agent gets); apply it
		# the same way Windows does. Fall back to the older git repo_url+branch
		# request below (applied at the agent's next normal restart) when no
		# archive_url is present, for backward compatibility.
		return start_agent_update(%cfg) if (($cfg{archive_url} || '') ne '');

	my $component = $cfg{component} || 'linux_agent';
	my $repo_url = $cfg{repo_url} || '';
	my $branch = $cfg{branch} || '';
	my $source_path = $cfg{source_path} || '';
	my $timeout = ($cfg{timeout} && $cfg{timeout} =~ /^[0-9]+$/) ? $cfg{timeout} : 60;
	return component_update_response(success => 0, status => 'invalid_component', message => 'Invalid component.') if($component ne 'linux_agent' && $component ne 'windows_agent');
	return component_update_response(success => 0, status => 'invalid_repo', message => 'Invalid repository URL or path.') if($repo_url !~ m{^(https?://|ssh://|git@|/)} || $repo_url =~ /[\r\n\0]/);
	return component_update_response(success => 0, status => 'invalid_branch', message => 'Invalid branch.') if($branch !~ /^[A-Za-z0-9._\/-]{1,128}$/);
	return component_update_response(success => 0, status => 'invalid_source_path', message => 'Invalid source path.') if($source_path eq '' || $source_path =~ /\.\./ || $source_path =~ /[\r\n\0]/ || $source_path !~ /^[A-Za-z0-9._\/-]+$/);

	my $ts = time();
	my $update_id = "restart-$ts";
	my $revision_file = Path::Class::File->new(AGENT_RUN_DIR, '.agent_core_source_revision')->stringify;
	my $current_commit = agent_read_first_line($revision_file);
	$current_commit =~ s/\s+$//;
	my %request = (
		update_id => $update_id,
		status => 'pending',
		component => $component,
		repo_url => $repo_url,
		branch => $branch,
		source_path => $source_path,
		timeout => $timeout,
		requested_os => $cfg{requested_os} || '',
		queued_at => scalar gmtime($ts),
		state_path => AGENT_UPDATE_STATE_FILE . '',
		request_path => AGENT_UPDATE_REQUEST_FILE . '',
		log_path => AGENT_UPDATE_LOG_FILE . ''
	);
	my %state = (
		success => 0,
		status => 'pending',
		message => 'Agent update request queued. It will be applied by the startup wrapper on the next normal restart when agent_auto_update is enabled.',
		update_id => $update_id,
		repo_url => $repo_url,
		branch => $branch,
		source_path => $source_path,
		target_commit => '',
		current_commit => $current_commit,
		rollback_performed => 0,
		version_before => AGENT_VERSION,
		version_after => '',
		state_path => AGENT_UPDATE_STATE_FILE . '',
		request_path => AGENT_UPDATE_REQUEST_FILE . '',
		log_path => AGENT_UPDATE_LOG_FILE . ''
	);
	my $request_tmp = AGENT_UPDATE_REQUEST_FILE . ".tmp.$$";
	my $state_tmp = AGENT_UPDATE_STATE_FILE . ".tmp.$$";
	my $request_fh;
	if(!open($request_fh, '>', $request_tmp))
	{
		return component_update_response(success => 0, status => 'write_failed', message => "Cannot write update request: $!");
	}
	print $request_fh encode_json(\%request) . "\n";
	close($request_fh);
	my $state_fh;
	if(!open($state_fh, '>', $state_tmp))
	{
		unlink $request_tmp;
		return component_update_response(success => 0, status => 'write_failed', message => "Cannot write update state: $!");
	}
	print $state_fh encode_json(\%state) . "\n";
	close($state_fh);
	if(!rename($request_tmp, AGENT_UPDATE_REQUEST_FILE) || !rename($state_tmp, AGENT_UPDATE_STATE_FILE))
	{
		unlink $request_tmp;
		unlink $state_tmp;
		return component_update_response(success => 0, status => 'write_failed', message => "Cannot publish update request/state: $!");
	}
	logger "Agent update request queued for $component from $repo_url branch $branch; it will apply on restart.";
	return component_update_response(%state, success => 1, status => 'queued');
}

sub component_update_shell_quote
{
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/'/'"'"'/g;
	return "'" . $value . "'";
}

sub component_update_response
{
	my (%data) = @_;
	my %encoded = ();
	foreach my $key (keys %data)
	{
		$encoded{$key} = encode_base64(defined $data{$key} ? $data{$key} : '', '');
	}
	return \%encoded;
}

sub component_update_parse_payload
{
	my ($payload) = @_;
	my %data = ();
	foreach my $line (split(/\r?\n/, $payload || ''))
	{
		next if $line !~ /^([A-Za-z0-9_]+)=(.*)$/;
		$data{$1} = decode_base64($2);
	}
	return %data;
}

sub component_update
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($payload) = decrypt_params(@_);
	my %cfg = component_update_parse_payload($payload);

	my $component = $cfg{component} || 'linux_agent';
	if ($component ne 'linux_agent' && $component ne 'windows_agent')
	{
		return component_update_response(success => 0, status => 'invalid_component', message => 'Invalid component.');
	}
	my $repo_url = $cfg{repo_url} || '';
	my $branch = $cfg{branch} || '';
	my $source_path = $cfg{source_path} || '';
	my $install_path = $cfg{install_path} || AGENT_RUN_DIR;
	my $git_path = $cfg{git_path} || 'git';
	my $backup_path = $cfg{backup_path} || Path::Class::Dir->new(AGENT_RUN_DIR, 'component_backups')->stringify;
	my $post_update_command = $cfg{post_update_command} || '';

	if ($repo_url !~ m{^(https?://|ssh://|git@|/)} || $repo_url =~ /[\r\n\0]/)
	{
		return component_update_response(success => 0, status => 'invalid_repo', message => 'Invalid repository URL or path.');
	}
	if ($branch !~ /^[A-Za-z0-9._\/-]{1,128}$/)
	{
		return component_update_response(success => 0, status => 'invalid_branch', message => 'Invalid branch.');
	}
	if ($source_path eq '' || $source_path =~ /\.\./ || $source_path =~ /[\r\n\0]/ || $source_path !~ /^[A-Za-z0-9._\/-]+$/)
	{
		return component_update_response(success => 0, status => 'invalid_source_path', message => 'Invalid source path.');
	}
	if ($install_path !~ m{^/} || $install_path =~ /\.\./ || $install_path =~ /[\r\n\0]/)
	{
		return component_update_response(success => 0, status => 'invalid_install_path', message => 'Invalid install path.');
	}
	if ($post_update_command =~ /[\r\n\0]/)
	{
		return component_update_response(success => 0, status => 'invalid_post_update', message => 'Post-update command must be a single line.');
	}

	my $ts = time();
	my $script_path = Path::Class::File->new(AGENT_RUN_DIR, "component_update_$ts.sh")->stringify;
	my $log_path = Path::Class::File->new(AGENT_RUN_DIR, 'component_update.log')->stringify;
	my $screenrc = SCREENRC_FILE;
	my $repo_q = component_update_shell_quote($repo_url);
	my $branch_q = component_update_shell_quote($branch);
	my $source_q = component_update_shell_quote($source_path);
	my $install_q = component_update_shell_quote($install_path);
	my $git_q = component_update_shell_quote($git_path);
	my $backup_q = component_update_shell_quote($backup_path);
	my $post_q = component_update_shell_quote($post_update_command);
	my $log_q = component_update_shell_quote($log_path);
	my $screenrc_q = component_update_shell_quote($screenrc);

	my $script = <<"EOS";
#!/usr/bin/env bash
set -u
LOG=$log_q
log(){ printf '[%s] %s\\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*" >> "\$LOG"; }
fail(){ log "FAILED: \$*"; exit 1; }
REPO=$repo_q
BRANCH=$branch_q
SOURCE_REL=$source_q
DEST=$install_q
GIT_BIN=$git_q
BACKUP_BASE=$backup_q
POST_UPDATE=$post_q
TMP="\${TMPDIR:-/tmp}/agent_core_update_\$(date +%s)_\$\$"
mkdir -p "\$TMP" "\$BACKUP_BASE" || fail "Cannot create staging or backup directories"
log "queued component=$component repo=\$REPO branch=\$BRANCH source=\$SOURCE_REL dest=\$DEST"
if ! command -v "\$GIT_BIN" >/dev/null 2>&1 && [ ! -x "\$GIT_BIN" ]; then
  fail "Git executable not found: \$GIT_BIN"
fi
"\$GIT_BIN" clone --depth 1 --branch "\$BRANCH" "\$REPO" "\$TMP/repo" >> "\$LOG" 2>&1 || fail "git clone failed"
SRC="\$TMP/repo/\$SOURCE_REL"
[ -d "\$SRC" ] || fail "Source component folder missing: \$SRC"
if [ "$component" = "linux_agent" ]; then
  for file in steamcmd/steamcmd.sh steamcmd/linux32/steamcmd steamcmd/linux32/steamerrorreporter steamcmd/linux32/libstdc++.so.6 steamcmd/linux32/crashhandler.so; do
    [ -s "\$SRC/\$file" ] || fail "SteamCMD bootstrap missing from source payload: \$file"
  done
  [ -x "\$SRC/steamcmd/steamcmd.sh" ] || fail "SteamCMD bootstrap is not executable: steamcmd/steamcmd.sh"
  [ -x "\$SRC/steamcmd/linux32/steamcmd" ] || fail "SteamCMD bootstrap is not executable: steamcmd/linux32/steamcmd"
fi
case "\$DEST" in /*) ;; *) fail "Destination must be absolute: \$DEST" ;; esac
mkdir -p "\$DEST" || fail "Cannot create destination: \$DEST"
ARCHIVE="\$BACKUP_BASE/${component}_\$(date +%Y%m%d_%H%M%S).tar.gz"
tar --exclude='./Cfg' --exclude='./ServerFiles' --exclude='./Schedule' --exclude='./logs' --exclude='./screenlogs' --exclude='./steamcmd' --exclude='./startups' --exclude='./homes' --exclude='./tmp' --exclude='./shared' --exclude='./component_backups' --exclude='./*.pid' -czf "\$ARCHIVE" -C "\$DEST" . >> "\$LOG" 2>&1 || fail "Backup failed"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude='Cfg/' --exclude='ServerFiles/' --exclude='Schedule/' --exclude='logs/' --exclude='screenlogs/' --exclude='steamcmd/' --exclude='startups/' --exclude='homes/' --exclude='tmp/' --exclude='shared/' --exclude='component_backups/' --exclude='*.pid' "\$SRC"/ "\$DEST"/ >> "\$LOG" 2>&1 || fail "rsync copy failed"
else
  (cd "\$SRC" && tar --exclude='./Cfg' --exclude='./ServerFiles' --exclude='./Schedule' --exclude='./logs' --exclude='./screenlogs' --exclude='./steamcmd' --exclude='./startups' --exclude='./homes' --exclude='./tmp' --exclude='./shared' --exclude='./component_backups' --exclude='./*.pid' -cf - .) | (cd "\$DEST" && tar -xf -) >> "\$LOG" 2>&1 || fail "tar copy failed"
fi
if [ "$component" = "linux_agent" ]; then
  for file in steamcmd/steamcmd.sh steamcmd/linux32/steamcmd steamcmd/linux32/steamerrorreporter steamcmd/linux32/libstdc++.so.6 steamcmd/linux32/crashhandler.so; do
    if [ ! -e "\$DEST/\$file" ]; then
      mkdir -p "\$(dirname "\$DEST/\$file")" || fail "Cannot create SteamCMD bootstrap directory"
      cp -p "\$SRC/\$file" "\$DEST/\$file" || fail "Cannot restore SteamCMD bootstrap file: \$file"
    fi
  done
  chmod +x "\$DEST/steamcmd/steamcmd.sh" "\$DEST/steamcmd/linux32/steamcmd" 2>/dev/null || true
fi
if [ -f "\$DEST/agent_core.pl" ]; then
  perl -c "\$DEST/agent_core.pl" >> "\$LOG" 2>&1 || fail "Updated agent_core.pl failed syntax validation"
fi
if [ -n "\$POST_UPDATE" ]; then
  (cd "\$DEST" && bash -lc "\$POST_UPDATE") >> "\$LOG" 2>&1 || fail "post-update command failed"
fi
log "copy complete archive=\$ARCHIVE"
sleep 2
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^agent_core\\.service'; then
  systemctl restart agent_core.service >> "\$LOG" 2>&1 && exit 0
fi
cd "\$DEST" || exit 0
if [ -f agent_core_run.pid ]; then kill "\$(cat agent_core_run.pid)" >/dev/null 2>&1 || true; fi
if [ -f agent_core.pid ]; then kill "\$(cat agent_core.pid)" >/dev/null 2>&1 || true; fi
sleep 2
if [ -f agent_core_run ]; then
  screen -d -m -t "agent_core" -c $screenrc_q -S agent_core bash agent_core_run -pidfile agent_core_run.pid >> "\$LOG" 2>&1 || true
else
  screen -d -m -t "agent_core" -c $screenrc_q -S agent_core perl agent_core.pl >> "\$LOG" 2>&1 || true
fi
log "restart attempted"
rm -rf "\$TMP"
exit 0
EOS

	my $fh;
	if (!open($fh, '>', $script_path))
	{
		return component_update_response(success => 0, status => 'write_failed', message => "Cannot write updater script: $!");
	}
	print $fh $script;
	close($fh);
	chmod 0700, $script_path;
	system('screen -d -m -t "component_update" -c "' . SCREENRC_FILE . '" -S component_update bash ' . component_update_shell_quote($script_path));
	if ($? != 0)
	{
		system('bash ' . component_update_shell_quote($script_path) . ' >/dev/null 2>&1 &');
	}
	logger "Component update queued for $component from $repo_url branch $branch.";
	return component_update_response(success => 1, status => 'queued', message => 'Component update queued on agent.', log_path => $log_path, script_path => $script_path);
}

sub agent_restart
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $dec_check = decrypt_param(@_);
	if ($dec_check eq 'restart')
	{
			# Installs done by the current installer run the agent as a systemd
			# service (agent_core, or gse-agent-<id> if that name was taken; see
			# Cfg::Config{service_name}, set by the installer). Restart through
			# systemd when that unit is active, mirroring how the Windows agent
			# restarts its Windows service; fall back to the legacy screen-based
			# restart below for older or manually-run installs with no service.
			my $service = $Cfg::Config{service_name} || 'agent_core';
			$service = 'agent_core' unless $service =~ /^[A-Za-z0-9_.-]{1,64}$/;
			if (system("systemctl is-active --quiet $service") == 0)
			{
				system("bash -c 'sleep 2; systemctl restart $service' >/dev/null 2>&1 &");
				return 1;
			}

			chdir AGENT_RUN_DIR;
			if(-e "agent_core_run.pid")
			{
				my $run_pid_file = "agent_core_run.pid";
			my $init_pid	= `cat $run_pid_file`;
			chomp($init_pid);

			if(kill 0, $init_pid)
			{
				my $or_exist	= "";
				my $rm_pid_file	= "";
				if(-e "agent_core.pid")
				{
					$rm_pid_file	= " agent_core.pid";
					my $agent_pid	= `cat agent_core.pid`;
					chomp($agent_pid);
					if( kill 0, $agent_pid )
					{
						$or_exist = " -o -e /proc/$agent_pid";
					}
				}

				open (AGENT_RESTART_SCRIPT, '>', 'tmp_restart.sh');
				my $restart = "echo -n \"Stopping GSE Agent...\"\n".
							  "kill $init_pid\n".
							  "while [ -e /proc/$init_pid $or_exist ];do echo -n .;sleep 1;done\n".
								  "rm -f agent_core_run.pid $rm_pid_file\necho \" [OK]\"\n".
							  "echo -n \"Starting GSE Agent...\"\n".
							  "screen -d -m -t \"agent_core\" -c \"" . SCREENRC_FILE . "\" -S agent_core bash agent_core_run -pidfile agent_core_run.pid\n".
							  "while [ ! -e agent_core_run.pid -o ! -e agent_core.pid ];do echo -n .;sleep 1;done\n".
							  "echo \" [OK]\"\n".
							  "rm -f tmp_restart.sh\n".
							  "exit 0\n";
				print AGENT_RESTART_SCRIPT $restart;
				close (AGENT_RESTART_SCRIPT);
				if( -e 'tmp_restart.sh' )
				{
					system('screen -d -m -t "agent_restart" -c "' . SCREENRC_FILE . '" -S agent_restart bash tmp_restart.sh');
				}
			}
		}
	}
	return -1;
}

# Subroutines to be called
sub scheduler_dispatcher {
	my ($task, $args) = @_;
	my $response = `$args`;
	chomp($response);
	my $log = "Executed command: $args";
	if($response ne "")
	{
		$log .= ", response:\n$response";
	}
	scheduler_log_events($log);
}

sub collect_and_submit_resource_stats {
	my ($task, $args) = @_;

	logger "Automated resource stats collection started.";
	scheduler_log_events("Resource stats collection started");

	eval {
		# Collect all resource statistics
		# Get CPU usage
		my %prev_idle;
		my %prev_total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$prev_idle{$1} = $stat[4];
			$prev_total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		sleep 1;
		my %idle;
		my %total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$idle{$1} = $stat[4];
			$total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		my $total_cpu_usage = 0;
		my $cpu_core_count = 0;
		foreach my $key ( keys %idle )
		{
			my $diff_idle = $idle{$key} - $prev_idle{$key};
			my $diff_total = $total{$key} - $prev_total{$key};
			my $percent = (100 * ($diff_total - $diff_idle)) / $diff_total;
			$percent = sprintf "%.2f", $percent unless $percent == 0;
			$total_cpu_usage += $percent;
			$cpu_core_count++;
		}
		my $avg_cpu_usage = $cpu_core_count > 0 ? sprintf("%.2f", $total_cpu_usage / $cpu_core_count) : 0;

		# Get RAM usage
		my($mem_total, $buffers, $cached, $mem_free) = qw(0 0 0 0);
		open(STAT, '/proc/meminfo');
		while (<STAT>) {
			$mem_total   += $1 if /MemTotal\:\s+(\d+) kB/;
			$buffers += $1 if /Buffers\:\s+(\d+) kB/;
			$cached  += $1 if /Cached\:\s+(\d+) kB/;
			$mem_free    += $1 if /MemFree\:\s+(\d+) kB/;
		}
		close STAT;
		my $mem_used = $mem_total - $mem_free - $cached - $buffers;
		my $mem_percent = $mem_total > 0 ? sprintf("%.2f", 100 * $mem_used / $mem_total) : 0;
		$mem_total *= 1024; # Convert to bytes
		$mem_used *= 1024;  # Convert to bytes

		# Get disk usage
		my($disk_total, $disk_used, $disk_free) = split(' ', `df -lP 2>/dev/null|grep "^/dev/.*"|awk '{total+=\$2}{used+=\$3}{free+=\$4} END {print total, used, free}'`);
		my $disk_percent = $disk_total > 0 ? sprintf("%.2f", 100 * $disk_used / $disk_total) : 0;
		$disk_total *= 1024; # Convert to bytes
		$disk_used *= 1024;  # Convert to bytes
		$disk_free *= 1024;  # Convert to bytes

		# Get uptime
		open(STAT, '/proc/uptime');
		my $uptime = 0;
		while (<STAT>) {
			$uptime += $1 if /^([0-9]+)/;
		}
		close STAT;

		# Get load average
		my $load_avg_1min = "0";
		my $load_avg_5min = "0";
		my $load_avg_15min = "0";
		open(LOADAVG, '/proc/loadavg');
		while (<LOADAVG>) {
			if (/^(\S+)\s+(\S+)\s+(\S+)/) {
				$load_avg_1min = $1;
				$load_avg_5min = $2;
				$load_avg_15min = $3;
			}
		}
		close LOADAVG;

		# Log the collected statistics
		my $stats_summary = "CPU: ${avg_cpu_usage}%, Memory: ${mem_percent}% (${mem_used}/${mem_total} bytes), Disk: ${disk_percent}% (${disk_used}/${disk_total} bytes), Uptime: ${uptime}s, Load: ${load_avg_1min}/${load_avg_5min}/${load_avg_15min}";
		logger "Scheduled resource stats collection - $stats_summary";
		scheduler_log_events("Resource usage collected - $stats_summary");

		# Submit to database
		my $submit_result = submit_resource_stats_to_db($avg_cpu_usage, $mem_used, $mem_total, $mem_percent, $disk_used, $disk_total, $disk_free, $disk_percent, $uptime, $load_avg_1min, $load_avg_5min, $load_avg_15min);

		if ($submit_result == 1) {
			logger "Scheduled resource statistics successfully submitted to MySQL database.";
			scheduler_log_events("Resource stats successfully submitted to MySQL database");
		} elsif ($submit_result == -1) {
			logger "Scheduled resource stats: database not configured - skipping submission.";
			scheduler_log_events("Resource stats: database not configured - skipping submission");
		} else {
			logger "Scheduled resource stats: failed to submit to MySQL database - error occurred.";
			scheduler_log_events("Resource stats: failed to submit to MySQL database - error occurred");
		}
	};

	if ($@) {
		logger "Error in scheduled resource stats collection: $@";
		scheduler_log_events("Error in resource stats collection: $@");
	}
}

sub scheduler_server_action
{
	my ($task, $args) = @_;
	my ($action, @server_args) = split('\|\%\|', $args);
	if($action eq "%ACTION=start")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[6], $server_args[5]);
		my $ret = universal_start_without_decrypt(@server_args);
		if($ret == 1)
		{
			scheduler_log_events("Started server home ID $home_id on address $ip:$port");
		}
		else
		{
			scheduler_log_events("Failed starting server home ID $home_id on address $ip:$port (Check agent log)");
		}
	}
	elsif($action eq "%ACTION=stop")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[1], $server_args[2]);
		my $ret = stop_server_without_decrypt(@server_args);
		if($ret == 0)
		{
			scheduler_log_events("Stopped server home ID $home_id on address $ip:$port");
		}
		elsif($ret == 1)
		{
			scheduler_log_events("Failed stopping server home ID $home_id on address $ip:$port (Invalid IP:Port given)");
		}
	}
	elsif($action eq "%ACTION=restart")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[1], $server_args[2]);
		my $ret = restart_server_without_decrypt(@server_args, "scheduled_restart");
		if($ret == 1)
		{
			scheduler_log_events("Restarted server home ID $home_id on address $ip:$port");
		}
		elsif($ret == -1)
		{
			scheduler_log_events("Failed restarting server home ID $home_id on address $ip:$port (Server could not be started, check agent log)");
		}
		elsif($ret == -2)
		{
			scheduler_log_events("Failed restarting server home ID $home_id on address $ip:$port (Server could not be stopped, check agent log)");
		}
	}
	return 1;
}

sub scheduler_log_events
{
	my $logcmd	 = $_[0];
	$logcmd = localtime() . " $logcmd\n";
	logger "Can't open " . SCHED_LOG_FILE . " - $!" unless open(LOGFILE, '>>', SCHED_LOG_FILE);
	logger "Failed to lock " . SCHED_LOG_FILE . "." unless flock(LOGFILE, LOCK_EX);
	logger "Failed to seek to end of " . SCHED_LOG_FILE . "." unless seek(LOGFILE, 0, 2);
	logger "Failed to write to " . SCHED_LOG_FILE . "." unless print LOGFILE "$logcmd";
	logger "Failed to unlock " . SCHED_LOG_FILE . "." unless flock(LOGFILE, LOCK_UN);
	logger "Failed to close " . SCHED_LOG_FILE . "." unless close(LOGFILE);
}

sub scheduler_add_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $new_task = decrypt_param(@_);
	if (open(TASKS, '>>', SCHED_TASKS))
	{
		print TASKS "$new_task\n";
		logger "Created new task: $new_task";
		close(TASKS);
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		$cron->add_entry( "* * * * * */5", \&gm_monitor_all );   # re-register the game monitor job on every new scheduler object
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot create task: $new_task ( $! )";
	return -1;
}

sub scheduler_del_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $name = decrypt_param(@_);
	my @cronJobIDs = split(',', $name);
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	if(open(TASKS, '>', SCHED_TASKS))
	{
		foreach my $task ( @entries ) {
			next if ( grep { $_ eq $task->{args}[0]} @cronJobIDs );
			next unless $task->{args}[0] =~ /task_[0-9]*/;
			if(defined $task->{args}[1])
			{
				print TASKS join(" ", $task->{time}, $task->{args}[1]) . "\n";
			}
			else
			{
				print TASKS $task->{time} . "\n";
			}
		}
		close( TASKS );
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		$cron->add_entry( "* * * * * */5", \&gm_monitor_all );   # re-register the game monitor job on every new scheduler object
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot open file " . SCHED_TASKS . " for deleting task(s) id: $name ( $! )",1;
	return -1;
}

sub scheduler_edit_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($name, $new_task) = decrypt_params(@_);
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	if(open(TASKS, '>', SCHED_TASKS))
	{
		foreach my $task ( @entries ) {
			next unless $task->{args}[0] =~ /task_[0-9]*/;
			if($name eq $task->{args}[0])
			{
				print TASKS "$new_task\n";
			}
			else
			{
				if(defined $task->{args}[1])
				{
					print TASKS join(" ", $task->{time}, $task->{args}[1]) . "\n";
				}
				else
				{
					print TASKS $task->{time} . "\n";
				}
			}
		}
		close( TASKS );
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		$cron->add_entry( "* * * * * */5", \&gm_monitor_all );   # re-register the game monitor job on every new scheduler object
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot open file " . SCHED_TASKS . " for editing task id: $name ( $! )",1;
	return -1;
}

sub scheduler_read_tasks
{
	# The scheduler rebuilds its timetable every second, which starves seconds-based jobs, so ride this one.
	if( open(TASKS, '<', SCHED_TASKS) )
	{
		# Store built-in scheduler tasks before cleaning timetable
		my @entries = $cron->list_entries();
		my @builtin_tasks = ();

		# Only log detailed task information when there are actual user tasks to process
		my $user_task_count = 0;

		# Preserve built-in tasks (those not starting with 'task_')
		foreach my $entry (@entries) {
			my $is_user_task = 0;
			if (defined $entry->{args} && @{$entry->{args}} > 0) {
				my $first_arg = $entry->{args}->[0];
				# Check if this is a user-defined task (starts with 'task_')
				if (defined $first_arg && $first_arg =~ /^task_\d+$/) {
					$is_user_task = 1;
					$user_task_count++;
					logger "scheduler_read_tasks: Removing user task: $first_arg";
				}
			}

			# Keep all tasks that are NOT user-defined
			if (!$is_user_task) {
				push @builtin_tasks, $entry;
			}
		}

		# Only log when there are user tasks to process, reducing spam from built-in task preservation
		if ($user_task_count > 0) {
			logger "scheduler_read_tasks: Found " . @entries . " existing tasks, processing $user_task_count user tasks";
			logger "scheduler_read_tasks: Preserving " . @builtin_tasks . " built-in tasks";
		}

		# Clear the timetable
		$cron->clean_timetable();

		# Re-add built-in tasks
		foreach my $builtin_task (@builtin_tasks) {
			$cron->add_entry($builtin_task->{time}, $builtin_task->{dispatcher}, @{$builtin_task->{args}});
		}

		# Only log re-adding when there were user tasks processed
		if ($user_task_count > 0) {
			logger "scheduler_read_tasks: Re-added " . @builtin_tasks . " built-in tasks";
		}
	}
	else
	{
		logger "Error reading tasks file: $! (file: " . SCHED_TASKS . ")";
		scheduler_stop();
		return -1;
	}

	my $i = 0;
	my $task_count = 0;
	while (<TASKS>)
	{
		next if $_ =~ /^(#.*|[\s|\t]*?\n)/;
		my ($minute, $hour, $dayOfTheMonth, $month, $dayOfTheWeek, @args) = split(' ', $_);
		my $time = "$minute $hour $dayOfTheMonth $month $dayOfTheWeek";
		if("@args" =~ /^\%ACTION.*/)
		{
			$cron->add_entry($time, \&scheduler_server_action, 'task_' . $i++, "@args");
		}
		else
		{
			$cron->add_entry($time, 'task_' . $i++, "@args");
		}
		$task_count++;
	}
	close(TASKS);
	logger "Scheduler tasks file read successfully. Loaded $task_count task(s)." if $task_count > 0;
	return 1;
}

sub scheduler_stop
{
	my $pid;
	if(open(PIDFILE, '<', SCHED_PID))
	{
		$pid = <PIDFILE>;
		chomp $pid;
		close(PIDFILE);
		if($pid ne "")
		{
			if( kill 0, $pid )
			{
				my $cnt = kill 9, $pid;
				if ($cnt == 1)
				{
					unlink SCHED_PID;
					return 1;
				}
			}
		}
	}
	return -1;
}

sub scheduler_list_tasks
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	my %entries_array;
	foreach my $task ( @entries ) {
		if( defined $task->{args}[1] )
		{
			$entries_array{$task->{args}[0]} = encode_base64(join(" ", $task->{time}, $task->{args}[1]));
		}
		else
		{
			$entries_array{$task->{args}[0]} = encode_base64($task->{time});
		}
	}
	if( %entries_array )
	{
		return {%entries_array};
	}
	return -1;
}

sub get_file_part
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($file, $offset) = decrypt_params(@_);
	if (!open(FILE, '<', $file))
	{
		logger "ERROR - Can't open file $file for reading.";
		return -1;
	}

	binmode(FILE);

	if($offset != 0)
	{
		return -1 unless seek FILE, $offset, 0;
	}

	my $data = "";
	my ($n, $buf);
	my $limit = $offset + 60 * 57 * 1000; #Max 3420Kb (1000 iterations) (top statistics ~ VIRT 116m, RES 47m)
	while (($n = read FILE, $buf, 60 * 57) != 0 && $offset <= $limit ) {
		$data .= $buf;
		$offset += $n;
	}
	close(FILE);

    if( $data ne "" )
	{
		my $b64zlib = encode_base64(compress($data,9));
		return "$offset;$b64zlib";
	}
	else
	{
		return -1;
	}
}

sub stop_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $home_id = decrypt_param(@_);
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	system('screen -S '.$screen_id.' -p 0 -X stuff $\'\003\'');
	if ($? == 0)
	{
		return 0;
	}
	return 1
}

sub shell_action
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($action, $arguments) = decrypt_params(@_);

	if($action eq 'remove_file')
	{
		chomp($arguments);
		unlink($arguments);
		return "1;";
	}
	elsif($action eq 'remove_recursive')
	{
		my @items = split(';', $arguments);
		foreach my $item ( @items ) {
			chomp($item);
			if(-d $item)
			{
				pathrmdir($item);
			}
			else
			{
				unlink($item);
			}
		}
		return "1;";
	}
	elsif($action eq 'create_dir')
	{
		chomp($arguments);
		mkpath($arguments);
		return "1;";
	}
	elsif($action eq 'move')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			$dest = Path::Class::Dir->new($dest, basename($src));
			dirmove($src, $dest);
		}
		else
		{
			fmove($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'rename')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			dirmove($src, $dest);
		}
		else
		{
			fmove($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'copy')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			$dest = Path::Class::Dir->new($dest, basename($src));
			dircopy($src, $dest);
		}
		else
		{
			fcopy($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'touch')
	{
		chomp($arguments);
		open(FH, '>', $arguments);
		print FH "";
		close(FH);
		return "1;";
	}
	elsif($action eq 'size')
	{
		chomp($arguments);
		my $size = 0;
		if(-d $arguments)
		{
			find(sub { $size += -s }, $arguments ? $arguments : '.');
		}
		else
		{
			$size += (stat($arguments))[7];
		}
		return "1;" . encode_list($size);
	}
	elsif($action eq 'get_cpu_usage')
	{
		my %prev_idle;
		my %prev_total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$prev_idle{$1} = $stat[4];
			$prev_total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		sleep 1;
		my %idle;
		my %total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$idle{$1} = $stat[4];
			$total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		my %cpu_percent_usage;
		foreach my $key ( keys %idle )
		{
			my $diff_idle = $idle{$key} - $prev_idle{$key};
			my $diff_total = $total{$key} - $prev_total{$key};
			my $percent = (100 * ($diff_total - $diff_idle)) / $diff_total;
			$percent = sprintf "%.2f", $percent unless $percent == 0;
			$cpu_percent_usage{$key} = encode_base64($percent);
		}
		return {%cpu_percent_usage};
	}
	elsif($action eq 'get_ram_usage')
	{
		my($total, $buffers, $cached, $free) = qw(0 0 0 0);
		open(STAT, '/proc/meminfo');
		while (<STAT>) {
			$total   += $1 if /MemTotal\:\s+(\d+) kB/;
			$buffers += $1 if /Buffers\:\s+(\d+) kB/;
			$cached  += $1 if /Cached\:\s+(\d+) kB/;
			$free    += $1 if /MemFree\:\s+(\d+) kB/;
		}
		close STAT;
		my $used = $total - $free - $cached - $buffers;
		my $percent = 100 * $used / $total;
		my %mem_usage;
		$mem_usage{'used'}    = encode_base64($used * 1024);
		$mem_usage{'total'}   = encode_base64($total * 1024);
		$mem_usage{'percent'} = encode_base64($percent);
		return {%mem_usage};
	}
	elsif($action eq 'get_disk_usage')
	{
		my($total, $used, $free) = split(' ', `df -lP 2>/dev/null|grep "^/dev/.*"|awk '{total+=\$2}{used+=\$3}{free+=\$4} END {print total, used, free}'`);
		my $percent = 100 * $used / $total;
		my %disk_usage;
		$disk_usage{'free'}    = encode_base64($free * 1024);
		$disk_usage{'used'}    = encode_base64($used * 1024);
		$disk_usage{'total'}   = encode_base64($total * 1024);
		$disk_usage{'percent'} = encode_base64($percent);
		return {%disk_usage};
	}
	elsif($action eq 'get_uptime')
	{
		open(STAT, '/proc/uptime');
		my $uptime = 0;
		while (<STAT>) {
			$uptime += $1 if /^([0-9]+)/;
		}
		close STAT;
		my %upsince;
		$upsince{'0'} = encode_base64($uptime);
		$upsince{'1'} = encode_base64(time - $uptime);
		return {%upsince};
	}
	elsif($action eq 'get_tasklist')
	{
		my %taskList;
		$taskList{'task'} = encode_base64(qx[top -b -c -i -w512 -n2 -o+%CPU|awk '/^top/{i++}i==2'|grep 'PID' -A 30]);
		return {%taskList};
	}
	elsif($action eq 'get_timestamp')
	{
		return "1;" . encode_list(time);
	}
	return 0;
}

sub remote_query
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($protocol, $game_type, $ip, $c_port, $q_port, $s_port) = decrypt_params(@_);
	my $command = "which php-cgi 2>&1;echo \$?";
	my @cmdret = qx($command);
	chomp(@cmdret);
	my $ret = pop(@cmdret);
	chomp($ret);
	if ("X$ret" ne "X0")
	{
		return -1;
	}
	my $PHP_CGI = "@cmdret";
	my $php_query_dir = Path::Class::Dir->new(AGENT_RUN_DIR, 'php-query');
	if($protocol eq 'lgsl')
	{
		chdir($php_query_dir->subdir('lgsl'));
		my $cmd = $PHP_CGI .
				" -f lgsl_feed.php" .
				" lgsl_type=" . $game_type .
				" ip=" . $ip .
				" c_port=" . $c_port .
				" q_port=" . $q_port .
				" s_port=" . $s_port .
				" request=sp";
		my $response = `$cmd`;
		chomp($response);
		chdir(AGENT_RUN_DIR);
		if($response eq "FAILURE")
		{
			return -1;
		}
		return encode_base64($response, "");
	}
	elsif($protocol eq 'gameq')
	{
		chdir($php_query_dir->subdir('gameq'));
		my $cmd = $PHP_CGI .
				" -f gameq_feed.php" .
				" game_type=" . $game_type .
				" ip=" . $ip .
				" c_port=" . $c_port .
				" q_port=" . $q_port .
				" s_port=" . $s_port;
		my $response = `$cmd`;
		chomp($response);
		chdir(AGENT_RUN_DIR);
		if($response eq "FAILURE")
		{
			return -1;
		}
		return encode_base64($response, "");
	}
	return -1;
}

sub send_steam_guard_code
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $sgc) = decrypt_params(@_);
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	system('screen -S '.$screen_id.' -p 0 -X stuff "'.$sgc.'$(printf \\\\r)"');
	if ($? == 0)
	{
		return 0;
	}
	return 1
}

sub steam_workshop
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return steam_workshop_without_decrypt(decrypt_params(@_));
}

#### Run the steam client ####
### @return 1 If installation started
### @return -1 In error case.
sub steam_workshop_without_decrypt
{
	my ($home_id, $mods_full_path,
		$workshop_id, $mods_list,
		$regex, $mods_backreference_index,
		$variable, $place_after, $mod_string,
		$string_separator, $config_file_path,
		$post_install, $mod_names_list,
		$anonymous_login, $user, $pass,
		$download_method, $url_list, $filename_list) = @_;

	# Creates mods path if it doesn't exist
	my $owner = SERVER_RUNNER_USER;

	if(defined LINUX_USER_PER_GAME_SERVER && LINUX_USER_PER_GAME_SERVER eq "1"){
		$owner = `whoami`;
		chomp $owner;
	}

	if ( check_b4_chdir($mods_full_path, $owner) != 0)
	{
		return -1;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	my @workshop_mods = split /,/, $mods_list;
	my @installcmds;

	if($download_method eq 'steamcmd')
	{
		if ( check_steam_cmd_client() == -1 )
		{
			return -1;
		}
		my $steam_binary = STEAMCMD_CLIENT_BIN;
		my $installSteamFile = $screen_id . "_workshop.txt";
		my $installtxt = Path::Class::File->new(STEAMCMD_CLIENT_DIR, $installSteamFile);

		open  FILE, '>', $installtxt;
		print FILE "\@ShutdownOnFailedCommand 1\n";
		print FILE "\@NoPromptForPassword 1\n";
		if($anonymous_login eq "0")
		{
			print FILE "login $user $pass\n";
		}
		else
		{
			print FILE "login anonymous\n";
		}
		print FILE "force_install_dir \"$mods_full_path\"\n";
		foreach my $workshop_mod (@workshop_mods)
		{
			print FILE "workshop_download_item $workshop_id $workshop_mod\n";
		}
		print FILE "exit\n";
		close FILE;
		@installcmds = ("$steam_binary +runscript $installtxt +exit");
	}

	if($download_method eq 'steamapi')
	{
		my @urls =  split /,/, $url_list;
		my @filenames =  split /,/, $filename_list;
		my $index = 0;
		foreach my $workshop_mod_id (@workshop_mods)
		{
			my $steamcmd_download_path = '/steamapps/workshop/content/'.$workshop_id.'/'.$workshop_mod_id.'/';

			my $workshop_mod_path = $mods_full_path.$steamcmd_download_path;
			if(!-d $workshop_mod_path && !mkpath $workshop_mod_path)
			{
				logger "Folder $workshop_mod_path could not be created.";
				$index++;
				next;
			}
			my $url = $urls[$index];
			my $filename = $filenames[$index];
			my $download_file_path = Path::Class::File->new($workshop_mod_path, "$filename");
			$installcmds[$index] = "wget -O \"$download_file_path\" \"$url\"";
			$index++;
		}
	}

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log($home_id, $log_file);

	my $precmd = "";
	my $postcmd = "";

	$postcmd .= generate_post_install_scripts($mods_full_path, $workshop_id, $mods_list,
											  $regex, $mods_backreference_index,
											  $variable, $place_after, $mod_string,
											  $string_separator, $config_file_path,
											  $post_install, $mod_names_list, $home_id);

	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;

	if ( check_b4_chdir($bash_scripts_path, $owner) != 0)
	{
		return -1;
	}
	my $secure = "$bash_scripts_path/secure.sh";
	my $home_path = $mods_full_path;
	$home_path =~ s/('+)/'\"$1\"'/g;
	my $sec = $secure;
	$sec =~ s/('+)/'\"$1\"'/g;
	open  FILE, '>', $secure;
	print FILE	"chmod 771 '$home_path'\n".
				"rm -f '$sec'";
	close FILE;

	my $installfile = create_bash_scripts($mods_full_path, $bash_scripts_path, $precmd, $postcmd, @installcmds);

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");

	logger "Installing Steam Workshop content on server Home ID " . $home_id;
	system($screen_cmd);

	return 1;
}

sub	generate_post_install_scripts
{
	my ($mods_full_path, $workshop_id, $mods_list,
		$regex, $mods_backreference_index,
		$variable, $place_after, $mod_string,
		$string_separator, $config_file_path,
		$post_install, $mod_names_list, $home_id) = @_;

	my $post_install_scripts = "";
	my $mods_info_path = Path::Class::Dir->new(AGENT_RUN_DIR, 'WorkshopModsInfo');
	$post_install_scripts .= "mods_full_path=\"$mods_full_path\"\n".
							 "workshop_id=\"$workshop_id\"\n".
							 "home_id=\"$home_id\"\n".
							 "regex=\"$regex\"\n".
							 "mods_backreference_index=\"$mods_backreference_index\"\n".
							 "variable=\"$variable\"\n".
							 "place_after=\"$place_after\"\n".
							 "string_separator=\"$string_separator\"\n".
							 "config_file_path=\"$config_file_path\"\n".
							 "mods_info_path=\"$mods_info_path/\"\n".
							 "mods_info_home_path=\"$mods_info_path/home_$home_id/\"\n".
							 "workshop_status_path=\"$mods_full_path/WorkshopInstallStatus.json\"\n".
							 "write_workshop_status(){ status=\"\$1\"; message=\"\$2\"; now=\"\$(date '+%Y-%m-%d %H:%M:%S')\"; message_json=\$(printf '%s' \"\$message\"|sed 's/\\\\/\\\\\\\\/g;s/\"/\\\\\"/g'); printf '{\"operation\":\"steam_workshop\",\"home_id\":\"%s\",\"workshop_app_id\":\"%s\",\"status\":\"%s\",\"message\":\"%s\",\"updated_at\":\"%s\"}\\n' \"\$home_id\" \"\$workshop_id\" \"\$status\" \"\$message_json\" \"\$now\" > \"\$workshop_status_path\"; }\n".
							 "write_workshop_status running \"Workshop install running\"\n".
							 "trap 'rc=\$?; if [ \$rc -ne 0 ]; then write_workshop_status failed \"Workshop install failed\"; echo WORKSHOP_INSTALL_FAILED; fi' EXIT\n";
	my @workshop_mods = split /,/, $mods_list;
	my @mod_names = split /,/, $mod_names_list;

	my $index = 0;
	foreach my $workshop_mod_id (@workshop_mods)
	{
		my $steamcmd_download_path = '/steamapps/workshop/content/'.$workshop_id.'/'.$workshop_mod_id.'/';
		my $workshop_mod_path = $mods_full_path.$steamcmd_download_path;
		my $this_mod_string = $mod_string;
		if(!defined $this_mod_string || $this_mod_string eq '')
		{
			$this_mod_string = '%workshop_mod_id%';
		}
		$this_mod_string =~ s/\%workshop_mod_id\%/$workshop_mod_id/g;

		$post_install_scripts .= "mod_string[$index]=\"$this_mod_string\"\n".
								 "mod_name[$index]=\"".$mod_names[$index]."\"\n".
								 "workshop_mod_id[$index]=\"$workshop_mod_id\"\n".
								 "workshop_mod_path[$index]=\"$workshop_mod_path\"\n";
		$index++;
	}

	$post_install_scripts .= 'i=0'."\n".
							 'for mod_id in "${workshop_mod_id[@]}"'."\n".
							 'do'."\n".
							 '	first_file="$(ls "${workshop_mod_path[$i]}"| sort -n | head -1)"'."\n";

	my @post_install_lines = split /[\r\n]+/, $post_install;
	foreach my $line (@post_install_lines) {
		if($line ne ""){
			$line =~ s/\%mods_full_path\%/\$mods_full_path/g;
			$line =~ s/\%workshop_mod_id\%/\$mod_id/g;
			$line =~ s/\%first_file\%/\$first_file/g;
			$post_install_scripts .= "\t".$line."\n";
		}
	}

	$post_install_scripts .= '	first_file_string="\%first_file%"'."\n".
							 '	if [ -z "${mod_string[$i]##*$first_file_string*}" ];then'."\n".
							 '		mod_string[$i]="${mod_string[$i]/$first_file_string/$first_file}"'."\n".
							 '	fi'."\n";

	if(defined $config_file_path && $config_file_path ne '')
	{
		$post_install_scripts .= '	if [ ! -e "$config_file_path" ];then'."\n".
								 '		if [ ! -d "$(dirname "$config_file_path")" ];then mkdir -p "$(dirname "$config_file_path")";fi'."\n".
								 '		echo -e "${place_after}\n${variable}" > "$config_file_path"'."\n".
								 '	fi'."\n".
								 '	file_content=$(cat "$config_file_path")'."\n".
								 '	if [[ $file_content =~ $regex ]]; then'."\n".
								 '		full_match="${BASH_REMATCH[0]}"'."\n".
								 '		mods_match="${BASH_REMATCH[$mods_backreference_index]}"'."\n".
								 '		found=1'."\n".
								 '	else'."\n".
								 '		found=0'."\n".
								 '	fi'."\n".
								 '	if [ $found == 1 ] && [ "X$full_match" != "X" ];then'."\n".
								 '		if [ "X$mods_match" == "X" ];then'."\n".
								 '			new_mods=$(echo -e "${full_match}${mod_string[$i]}")'."\n".
								 '			echo -e "${file_content/$full_match/$new_mods}">"$config_file_path"'."\n".
								 '		else'."\n".
								 '			if [ ! -z "${mods_match##*${mod_string[$i]}*}" ];then'."\n".
								 '				new_mods=$(echo -e "${full_match}${string_separator}${mod_string[$i]}")'."\n".
								 '				echo -e "${file_content/$full_match/$new_mods}">"$config_file_path"'."\n".
								 '			fi'."\n".
								 '		fi'."\n".
								 '	else'."\n".
								 '		if [ "X$place_after" == "X" ];then'."\n".
								 '			echo -e "${file_content}${variable}${mod_string[$i]}">"$config_file_path"'."\n".
								 '		else'."\n".
								 '			if [ -z "${file_content##*${place_after}*}" ];then'."\n".
								 '				new_var="${variable}${mod_string[$i]}"'."\n".
								 '				place_after_esc=$(echo -e "$place_after"|sed -e \'s/[]\\/$*.^[]/\\\\&/g\')'."\n".
								 '				echo -e "$file_content"|sed \'/\'$place_after_esc\'/a \'$new_var>"$config_file_path"'."\n".
								 '			else'."\n".
								 '				echo -e "${file_content}${place_after}\n${variable}${mod_string[$i]}">"$config_file_path"'."\n".
								 '			fi'."\n".
								 '		fi'."\n".
								 '	fi'."\n";
	}

	$post_install_scripts .=
							 '	if [ ! -d "${mods_info_path}" ];then mkdir -p "${mods_info_path}";fi'."\n".
							 '	if [ ! -d "${mods_info_home_path}" ];then mkdir -p "${mods_info_home_path}";fi'."\n".
							 '	installed_path=""'."\n".
							 '	if [ -e "$mods_full_path/${mod_string[$i]}" ];then installed_path="$mods_full_path/${mod_string[$i]}";fi'."\n".
							 '	if [ -z "$installed_path" ] && [ -e "$mods_full_path/@$mod_id" ];then installed_path="$mods_full_path/@$mod_id";fi'."\n".
							 '	if [ -z "$installed_path" ] && [ -e "$mods_full_path/$mod_id" ];then installed_path="$mods_full_path/$mod_id";fi'."\n".
							 '	installed_folder="$(basename "$installed_path")"'."\n".
							 "	install_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"\n".
							 '	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "${mod_string[$i]}" "$mod_id" "${mod_name[$i]}" "$installed_folder" "$installed_path" "$workshop_id" "installed" "$install_time" "$install_time" > "${mods_info_home_path}${mod_id}.gspmod"'."\n".
							 '	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "${mod_string[$i]}" "$mod_id" "${mod_name[$i]}" "$installed_folder" "$installed_path" "$workshop_id" "installed" "$install_time" "$install_time" > "${mods_info_path}${mod_string[$i]}.gspmod"'."\n".
							 '	i=$(expr $i + 1)'."\n".
							 'done'."\n".
							 'write_workshop_status completed "Workshop install completed"'."\n".
							 'trap - EXIT'."\n".
							 'echo WORKSHOP_INSTALL_COMPLETE'."\n";
	return "$post_install_scripts";
}

sub get_workshop_mods_info()
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");

	my ($home_id) = decrypt_params(@_);
	my $mods_info_dir_path = Path::Class::Dir->new(AGENT_RUN_DIR, 'WorkshopModsInfo');
	if(defined $home_id && $home_id =~ /^\d+$/)
	{
		my $home_mods_info_dir_path = Path::Class::Dir->new($mods_info_dir_path, "home_$home_id");
		$mods_info_dir_path = $home_mods_info_dir_path if(-d $home_mods_info_dir_path);
	}

	if(-d $mods_info_dir_path)
	{
		opendir(MODS_INFO_DIR, $mods_info_dir_path) or return -1;
		my @mods_info;
		while(my $mod_info_file = readdir(MODS_INFO_DIR))
		{
			if($mod_info_file =~ /\.gspmod$/)
			{
				my $mod_info_file_path = Path::Class::File->new($mods_info_dir_path, $mod_info_file);
				if(open(my $fh, '<:encoding(UTF-8)', $mod_info_file_path))
				{
					my $row = <$fh>;
					chomp $row;
					if($row ne "")
					{
						my ($string_name, $ext) = split(/\.gsp/, $mod_info_file);
						if(index($row, "\t") >= 0)
						{
							push @mods_info, $row;
						}
						else
						{
							push @mods_info, "$string_name:$row";
						}
					}
					close($fh);
				}
			}
		}
		closedir(MODS_INFO_DIR);
		return "1;".encode_list(@mods_info);
	}

	return -1;
}

sub get_setting_using_api
{
	my ($setting_name) = @_;

	if(defined WEB_API_URL && WEB_API_URL ne "" && defined WEB_ADMIN_API_KEY && WEB_ADMIN_API_KEY ne ""){
		my $url = WEB_API_URL . "?setting/get&setting_name=" . $setting_name . "&token=" . WEB_ADMIN_API_KEY;
		my $ua = LWP::UserAgent->new;
		$ua->agent('Mozilla/5.0');
		$ua->timeout(5);
		$ua->ssl_opts( verify_hostname => 0 ,SSL_verify_mode => 0x00);
		my $response = $ua->get($url);
		return $response->decoded_content();
	}

	return -1;
}

sub is_integer {
   defined $_[0] && $_[0] =~ /^[+-]?\d+$/;
}

sub get_minecraft_rcon_port{
	my ($home_dir) = @_;
	my $port = -1;
	my $findStr = "rcon.port=";
	my $file = Path::Class::File->new($home_dir, "server.properties");

	open(FH, '<', $file) or return -1;

	while(<FH>){
		if (begins_with($_,$findStr)){
			$port = int(substr($_, length($findStr)));
			last;
		}
	}

	close(FH);

	return $port;
}

sub begins_with
{
    return substr($_[0], 0, length($_[1])) eq $_[1];
}

sub generate_random_password{
	my ($length) = @_;
	my @alphanumeric = ('a'..'z', 'A'..'Z', 0..9,'!','_','-');
	my @numeric = (0..9);
	my $randpassword = '';

	if(not defined $length || not is_integer($length)){
		$length = 16;
	}

	until ( length($randpassword) > $length ) {
			$randpassword = $randpassword . join '', map $alphanumeric[rand @alphanumeric], 0..(rand @numeric);
	}

	return $randpassword;
}

sub trim{
	my $s = shift;
	$s =~ s/^\s+|\s+$//g;
	return $s
}
