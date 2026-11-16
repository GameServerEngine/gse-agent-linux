use strict;
use warnings;
use Cwd ();
use File::Glob qw(bsd_glob GLOB_NOSORT);
use File::Temp qw(tempdir);
# Tests wildcard log resolution (resolve_latest_log_match) extracted from agent_core.pl.
my $src_file = shift @ARGV or die "usage: validate_get_log_wildcard.pl agent_core.pl\n";
open my $fh, '<', $src_file or die "open: $!";
my $src = do { local $/; <$fh> };
my ($subs) = $src =~ /(^sub log_path_has_wildcards\b.*?)(?=^### Return -10)/ms or die "no subs block";
eval "package T; use strict; use warnings; use File::Glob qw(bsd_glob GLOB_NOSORT); $subs\n1;" or die "eval: $@";

my $root = tempdir(CLEANUP => 1);
my $home = "$root/home";
my $out  = "$root/outside";
mkdir $_ for $home, "$home/logs", $out;
sub touch { my ($f, $t) = @_; open my $o, '>', $f or die; print $o "x\n"; close $o; utime $t, $t, $f if $t; }
touch("$home/logs/latest.log", 1000);
touch("$home/logs/server_a.log", 2000);
touch("$home/logs/server_b.log", 3000);
touch("$home/logs/server_c.log", 3000);   # same time as b: lexically last wins
touch("$home/logs/SERVER_z.log", 9000);   # case differs: must not match
touch("$out/secret.log", 5000);
symlink "$out/secret.log", "$home/logs/server_link.log";
symlink $out, "$home/outdir";

my $fail = 0;
sub check { my ($name, $got, $want) = @_;
  $got = 'undef' unless defined $got;
  if ($got eq $want) { print "ok - $name\n" } else { print "not ok - $name (got $got, want $want)\n"; $fail++ } }
my $h = Cwd::abs_path($home);
check('exact path has no wildcard', T::log_path_has_wildcards('logs/latest.log'), 0);
check('wildcard detected', T::log_path_has_wildcards('logs/*.log'), 1);
check('newest of several, tie lexical', T::resolve_latest_log_match($home, 'logs/server_*.log'), "$h/logs/server_c.log");
check('question mark', T::resolve_latest_log_match($home, 'logs/server_?.log'), "$h/logs/server_c.log");
check('no match', T::resolve_latest_log_match($home, 'logs/none_*.log'), 'undef');
check('dotdot escape', T::resolve_latest_log_match($home, '../outside/*.log'), 'undef');
check('dotdot inside', T::resolve_latest_log_match($home, 'logs/../../outside/*.log'), 'undef');
check('absolute path', T::resolve_latest_log_match($home, "$out/*.log"), 'undef');
check('symlink dir outside', T::resolve_latest_log_match($home, 'outdir/*.log'), 'undef');
touch("$home/logs/only_x.log", 100);
symlink "$out/secret.log", "$home/logs/only_link.log";
check('symlink file outside skipped', T::resolve_latest_log_match($home, 'logs/only_*.log'), "$h/logs/only_x.log");
check('case sensitive', T::resolve_latest_log_match($home, 'logs/server_*.LOG'), 'undef');
exit($fail ? 1 : 0);
