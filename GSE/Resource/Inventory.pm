package GSE::Resource::Inventory;
# Read-only hardware inventory for the Linux agent (GSE Resource Intelligence, Phase 2).
# Reports what the machine can be seen to have. Unknown values are undef (JSON null), never 0.
# Units are explicit in key names: *_kib, *_mib, *_bytes. Reads only /proc, /sys and cgroup files;
# the one command run is `df` with a fixed argument list (no shell).
use strict;
use warnings;
use Exporter 'import';
use JSON::PP;

our @EXPORT_OK = qw(collect_linux_inventory);
use constant INVENTORY_SCHEMA_VERSION => 1;

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $text = <$fh>;
    close($fh);
    return $text;
}

sub _trim {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s eq '' ? undef : $s;
}

sub _meminfo_kib {
    my ($root, $key) = @_;
    my $text = _slurp("$root/proc/meminfo");
    return undef unless defined $text;
    return $text =~ /^\Q$key\E:\s+(\d+)\s+kB/m ? $1 + 0 : undef;
}

sub _cpu_model {
    my ($root) = @_;
    my $text = _slurp("$root/proc/cpuinfo");
    return undef unless defined $text;
    return $text =~ /^model name\s*:\s*(.+?)\s*$/m ? $1 : undef;
}

sub _logical_cpus_allowed {
    my ($root) = @_;
    my $text = _slurp("$root/proc/self/status");
    return (undef, undef) unless defined $text;
    my $list = $text =~ /^Cpus_allowed_list:\s*(\S+)/m ? $1 : undef;
    return (undef, undef) unless defined $list;
    my $count = 0;
    for my $part (split /,/, $list) {
        if ($part =~ /^(\d+)-(\d+)$/) { $count += $2 - $1 + 1 }
        elsif ($part =~ /^\d+$/)     { $count += 1 }
        else                          { return ($list, undef) }
    }
    return ($list, $count);
}

sub _cpu_quota {
    my ($root) = @_;
    # cgroup v2: "max 100000" or "<quota> <period>" in microseconds.
    my $v2 = _trim(_slurp("$root/sys/fs/cgroup/cpu.max"));
    if (defined $v2) {
        my ($quota, $period) = split /\s+/, $v2;
        return { source => 'cgroup_v2', quota_us => ($quota eq 'max' ? undef : $quota + 0),
                 period_us => ($period ? $period + 0 : undef), unlimited => ($quota eq 'max' ? JSON::PP::true : JSON::PP::false) };
    }
    # cgroup v1
    my $q = _trim(_slurp("$root/sys/fs/cgroup/cpu/cpu.cfs_quota_us"));
    my $p = _trim(_slurp("$root/sys/fs/cgroup/cpu/cpu.cfs_period_us"));
    if (defined $q && defined $p) {
        my $unlimited = $q + 0 < 0;
        return { source => 'cgroup_v1', quota_us => ($unlimited ? undef : $q + 0), period_us => $p + 0,
                 unlimited => ($unlimited ? JSON::PP::true : JSON::PP::false) };
    }
    return { source => 'none', quota_us => undef, period_us => undef, unlimited => undef };
}

sub _memory_limit_bytes {
    my ($root) = @_;
    my $v2 = _trim(_slurp("$root/sys/fs/cgroup/memory.max"));
    if (defined $v2) {
        return { source => 'cgroup_v2', limit_bytes => ($v2 eq 'max' ? undef : $v2 + 0) };
    }
    my $v1 = _trim(_slurp("$root/sys/fs/cgroup/memory/memory.limit_in_bytes"));
    if (defined $v1) {
        # v1 reports a huge number when unlimited.
        my $n = $v1 + 0;
        return { source => 'cgroup_v1', limit_bytes => ($n >= 2**62 ? undef : $n) };
    }
    return { source => 'none', limit_bytes => undef };
}

sub _hypervisor_flag {
    my ($root) = @_;
    my $text = _slurp("$root/proc/cpuinfo");
    return undef unless defined $text;
    return $text =~ /^flags\s*:.*\bhypervisor\b/m ? JSON::PP::true : JSON::PP::false;
}

sub _block_devices {
    my ($root) = @_;
    my $dir = "$root/sys/block";
    return [] unless -d $dir;
    opendir(my $dh, $dir) or return [];
    my @devs;
    for my $name (sort grep { !/^\./ && !/^(loop|ram|sr|md)\d*/ } readdir($dh)) {
        my $rot = _trim(_slurp("$dir/$name/queue/rotational"));
        my $size = _trim(_slurp("$dir/$name/size"));   # 512-byte sectors
        push @devs, {
            name => $name,
            rotational => (defined $rot ? ($rot eq '1' ? JSON::PP::true : JSON::PP::false) : undef),
            size_bytes => (defined $size ? $size * 512 : undef),
        };
    }
    closedir($dh);
    return \@devs;
}

sub _filesystem_for_path {
    my ($path) = @_;
    return { path => $path, total_bytes => undef, available_bytes => undef, error => 'missing path' }
        unless defined $path && -e $path;
    # Fixed argument list, no shell.
    my $pid = open(my $fh, '-|', 'df', '-P', '-B1', $path);
    return { path => $path, total_bytes => undef, available_bytes => undef, error => 'df unavailable' } unless $pid;
    my @lines = <$fh>;
    close($fh);
    my $line = $lines[-1] // '';
    my @f = split /\s+/, $line;
    return { path => $path, total_bytes => undef, available_bytes => undef, error => 'df parse failed' }
        unless @f >= 6 && $f[1] =~ /^\d+$/;
    return { path => $path, filesystem => $f[0], total_bytes => $f[1] + 0, available_bytes => $f[3] + 0, mount => $f[5] };
}

# Collect the Linux inventory. Options: root (filesystem root, tests use a fixture), game_path (volume to measure).
sub collect_linux_inventory {
    my (%opt) = @_;
    my $root = defined $opt{root} ? $opt{root} : '';
    my @warnings;

    my $kernel = _trim(_slurp("$root/proc/sys/kernel/osrelease"));
    my $arch = _trim(`uname -m 2>/dev/null`);
    my ($allowed_list, $allowed_count) = _logical_cpus_allowed($root);
    my $mem_total = _meminfo_kib($root, 'MemTotal');
    my $mem_avail = _meminfo_kib($root, 'MemAvailable');
    push @warnings, 'MemAvailable missing' unless defined $mem_avail;
    push @warnings, 'cpu model missing' unless defined _cpu_model($root);

    my $fs = _filesystem_for_path($opt{game_path});

    return {
        schema_version => INVENTORY_SCHEMA_VERSION,
        platform => 'linux',
        kernel => $kernel,
        architecture => $arch,
        cpu => {
            model => _cpu_model($root),
            logical_cpus_allowed => $allowed_count,
            cpus_allowed_list => $allowed_list,
            quota => _cpu_quota($root),
            hypervisor_flag => _hypervisor_flag($root),
        },
        memory => {
            total_mib => (defined $mem_total ? int($mem_total / 1024) : undef),
            available_mib => (defined $mem_avail ? int($mem_avail / 1024) : undef),
            cgroup_limit => _memory_limit_bytes($root),
        },
        storage => {
            game_volume => $fs,
            block_devices => _block_devices($root),
        },
        warnings => \@warnings,
    };
}

1;
