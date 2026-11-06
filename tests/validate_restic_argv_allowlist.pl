use strict;
use warnings;
# Checks the Linux restic argv allowlist against the same rules the Windows agent uses.
# It extracts the path and argv subs from gsp_agent.pl, so it runs without the agent's CPAN modules.
my $src_file = shift @ARGV or die "usage: validate_restic_argv_allowlist.pl gsp_agent.pl\n";
open my $fh, '<', $src_file or die "open: $!";
my $src = do { local $/; <$fh> };
delete $ENV{GSE_GAME_HOME_ROOT};    # test the default root
my ($const) = $src =~ /(use constant RESTIC_HOME_ROOT\s*=>[^;]*;)/ or die "no RESTIC_HOME_ROOT";
my ($subs) = $src =~ /(^\s*sub restic_arg_home_path_ok\b.*?)(?=^\s*sub restic_job_env_ok\b)/ms or die "no subs block";
my $code = "package T; use strict; use warnings; $const\n$subs\n1;\n";
eval $code or die "eval failed: $@";

my $HEX = 'ce543f700831536d829d767fe82bad280912e096b3e15b1b0a105ab4ce3875df';
my $G52 = '/home/gameserver/52';
my $EXCL = "$G52/restic-restore";
my @cases = (
  ['backup customer (must allow)', 1, ['restic','backup',$G52,'--exclude',$EXCL,'--tag','customer','--tag','home-52','--json']],
  ['backup baseline (must allow)', 1, ['restic','backup',$G52,'--exclude',$EXCL,'--tag','baseline','--tag','home-52','--json']],
  ['old 6-arg form (must reject)', 0, ['restic','backup',$G52,'--tag','customer','--tag','home-52','--json']],
  ['backup of / (must reject)',    0, ['restic','backup','/','--exclude',$EXCL,'--tag','customer','--tag','home-52','--json']],
  ['backup of root home (reject)', 0, ['restic','backup','/home/gameserver','--exclude','/home/gameserver/restic-restore','--tag','customer','--tag','home-52','--json']],
  ['backup /etc (must reject)',    0, ['restic','backup','/etc','--exclude','/etc/restic-restore','--tag','customer','--tag','home-52','--json']],
  ['backup with .. (must reject)', 0, ['restic','backup',"$G52/../53",'--exclude',"$G52/../53/restic-restore",'--tag','customer','--tag','home-52','--json']],
  ['backup trailing slash (reject)', 0, ['restic','backup',"$G52/",'--exclude',"$G52//restic-restore",'--tag','customer','--tag','home-52','--json']],
  ['exclude other game (reject)',  0, ['restic','backup',$G52,'--exclude','/home/gameserver/53/restic-restore','--tag','customer','--tag','home-52','--json']],
  ['exclude wrong name (reject)',  0, ['restic','backup',$G52,'--exclude',"$G52/gamefiles",'--tag','customer','--tag','home-52','--json']],
  ['bad tag kind (reject)',        0, ['restic','backup',$G52,'--exclude',$EXCL,'--tag','other','--tag','home-52','--json']],
  ['restore to staging (allow)',   1, ['restic','restore',$HEX,'--target',$EXCL]],
  ['restore include+staging (ok)', 1, ['restic','restore',$HEX,'--include',"$G52/gamefiles",'--target',$EXCL]],
  ['restore to / (must reject)',   0, ['restic','restore',$HEX,'--target','/']],
  ['restore to /home (reject)',    0, ['restic','restore',$HEX,'--target','/home']],
  ['restore to /etc (reject)',     0, ['restic','restore',$HEX,'--target','/etc']],
  ['restore bad snapshot (reject)',0, ['restic','restore','not-hex!','--target',$EXCL]],
  ['forget prune (allow)',         1, ['restic','forget','--prune',$HEX]],
  ['forget without prune (reject)',0, ['restic','forget',$HEX]],
  ['init (allow)',                 1, ['restic','init']],
  ['init with repo arg (reject)',  0, ['restic','init','-r','/tmp/x']],
  ['cat config (allow)',           1, ['restic','cat','config']],
  ['not restic (reject)',          0, ['sh','-c','id']],
  ['unknown subcommand (reject)',  0, ['restic','dump',$HEX]],
);
my $fail = 0;
for my $c (@cases) {
  my ($name, $want, $argv) = @$c;
  my $got = T::restic_job_argv_ok($argv) ? 1 : 0;
  my $ok = $got == $want;
  $fail++ unless $ok;
  printf "%-4s %s (got %d want %d)\n", ($ok ? 'ok' : 'FAIL'), $name, $got, $want;
}
print $fail ? "FAILURES: $fail\n" : "all passed\n";
exit($fail ? 1 : 0);
