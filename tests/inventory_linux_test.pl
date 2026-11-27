#!/usr/bin/perl
# Fixture tests for GSE::Resource::Inventory (no live /proc needed).
use strict;
use warnings;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/..";
use GSE::Resource::Inventory qw(collect_linux_inventory);
use JSON::PP;

my $fail = 0;
sub check { my ($ok, $name) = @_; print(($ok ? "ok" : "FAIL"), " - $name\n"); $fail++ unless $ok; }
sub write_file { my ($p, $t) = @_; make_path(dirname($p)); open(my $fh, ">", $p) or die $!; print $fh $t; close $fh; }

# Case 1: cgroup v2 with a CPU quota and a memory limit, Cpus_allowed_list with a range and a single CPU.
my $r1 = tempdir(CLEANUP => 1);
write_file("$r1/proc/cpuinfo", "processor\t: 0\nmodel name\t: Test CPU 3000\nflags\t\t: fpu hypervisor sse\n");
write_file("$r1/proc/meminfo", "MemTotal:       16777216 kB\nMemAvailable:    8388608 kB\n");
write_file("$r1/proc/self/status", "Name: perl\nCpus_allowed_list:\t0-3,6\n");
write_file("$r1/proc/sys/kernel/osrelease", "6.8.0-test\n");
write_file("$r1/sys/fs/cgroup/cpu.max", "200000 100000\n");
write_file("$r1/sys/fs/cgroup/memory.max", "8589934592\n");
my $i1 = collect_linux_inventory(root => $r1);
check($i1->{cpu}{logical_cpus_allowed} == 5, 'counts CPUs in a mixed range list (0-3,6 = 5)');
check($i1->{cpu}{model} eq 'Test CPU 3000', 'reads CPU model');
check($i1->{cpu}{hypervisor_flag} eq JSON_TRUE(), 'detects hypervisor flag');
check($i1->{cpu}{quota}{quota_us} == 200000 && $i1->{cpu}{quota}{period_us} == 100000, 'reads cgroup v2 quota');
check(!$i1->{cpu}{quota}{unlimited}, 'quota not reported unlimited when set');
check($i1->{memory}{total_mib} == 16384 && $i1->{memory}{available_mib} == 8192, 'memory in MiB from kB');
check($i1->{memory}{cgroup_limit}{limit_bytes} == 8589934592, 'reads cgroup v2 memory limit');

# Case 2: cgroup v1 with unlimited quota (-1) and unlimited memory (huge number).
my $r2 = tempdir(CLEANUP => 1);
write_file("$r2/proc/cpuinfo", "model name\t: Other\nflags\t\t: fpu sse\n");
write_file("$r2/proc/meminfo", "MemTotal:       4096 kB\n");
write_file("$r2/sys/fs/cgroup/cpu/cpu.cfs_quota_us", "-1\n");
write_file("$r2/sys/fs/cgroup/cpu/cpu.cfs_period_us", "100000\n");
write_file("$r2/sys/fs/cgroup/memory/memory.limit_in_bytes", "9223372036854771712\n");
my $i2 = collect_linux_inventory(root => $r2);
check($i2->{cpu}{quota}{source} eq 'cgroup_v1', 'uses cgroup v1 when v2 is absent');
check(!defined $i2->{cpu}{quota}{quota_us} && $i2->{cpu}{quota}{unlimited} eq JSON_TRUE(), 'v1 quota -1 means unlimited');
check(!defined $i2->{memory}{cgroup_limit}{limit_bytes}, 'huge v1 memory limit means no limit (null)');
check($i2->{cpu}{hypervisor_flag} eq JSON_FALSE(), 'no hypervisor flag reports false');

# Case 3: missing files must produce null, never 0, and be listed as warnings.
my $r3 = tempdir(CLEANUP => 1);
my $i3 = collect_linux_inventory(root => $r3);
check(!defined $i3->{memory}{available_mib}, 'missing MemAvailable is null, not 0');
check(!defined $i3->{cpu}{logical_cpus_allowed}, 'missing Cpus_allowed_list is null, not 0');
check(!defined $i3->{cpu}{hypervisor_flag}, 'missing cpuinfo gives null hypervisor flag');
check(scalar(@{$i3->{warnings}}) >= 1, 'missing data is reported in warnings');

# Case 4: game volume measures a real path with df and reports bytes.
my $i4 = collect_linux_inventory(root => $r1, game_path => $r1);
check($i4->{storage}{game_volume}{total_bytes} > 0, 'game volume total bytes from df');
my $i5 = collect_linux_inventory(root => $r1, game_path => '/nonexistent/path/xyz');
check($i5->{storage}{game_volume}{error} eq 'missing path' && !defined $i5->{storage}{game_volume}{total_bytes}, 'missing game path reports error, null bytes');

print $fail ? "\n$fail FAILED\n" : "\nall inventory tests passed\n";
exit($fail ? 1 : 0);

sub JSON_TRUE  { JSON::PP::true }
sub JSON_FALSE { JSON::PP::false }
