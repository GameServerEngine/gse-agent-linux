#!/usr/bin/perl
# Prints the process list for GameManagerLinux. Run as root (through the agent's sudo), so the
# games of every server user are visible. First line "GSE-PROC 1", then one line per process:
# pid, parent pid, short name, executable, working folder, command line (tab separated).
use strict;
use warnings;
print "GSE-PROC 1\n";
opendir(my $proc, '/proc') or exit 1;
for my $pid (grep { /^\d+$/ } readdir $proc) {
	open(my $fh, '<', "/proc/$pid/stat") or next;
	my $stat = <$fh>;
	close $fh;
	next unless defined $stat && $stat =~ /^\d+ \((.*)\) (\S) (\d+)/s;
	my ($name, $state, $ppid) = ($1, $2, $3);
	next if $state eq 'Z';
	my $exe = readlink("/proc/$pid/exe") // '';
	$exe =~ s/ \(deleted\)$//;
	my $cwd = readlink("/proc/$pid/cwd") // '';
	my $cmd = '';
	if (open(my $c, '<', "/proc/$pid/cmdline")) { local $/; $cmd = <$c> // ''; close $c; }
	$cmd =~ s/\0+\z//;
	tr/\t\n\0/   / for ($name, $exe, $cwd, $cmd);
	print join("\t", $pid, $ppid, $name, $exe, $cwd, $cmd), "\n";
}
closedir $proc;
